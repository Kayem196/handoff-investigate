const $ = id => document.getElementById(id);
const token = location.hash.slice(1);
let config, selected, pending, busy = false;
const failureMessages = {
  provider_auth_failed: 'The provider rejected this key or its permissions. Check AI settings.',
  provider_quota_exhausted: 'The provider account has no available API credit. Check its billing settings.',
  provider_rate_limited: 'The provider is limiting requests. Wait before trying again.',
  provider_model_not_found: 'The provider could not find this model. Check the model name and your access.',
  provider_unreachable: 'Handoff could not reach the provider. Check your connection, then try again.',
  provider_output_limit: 'The provider used the output budget before returning an answer. Try a more focused question.',
  provider_empty_response: 'The provider returned no answer. Try again or choose another model.',
  provider_redirect_rejected: 'The provider returned a redirect. Handoff refused to follow it.'
};

async function api(action, body = {}) {
  const response = await fetch(`/api/${action}`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Handoff-Session': token }, body: JSON.stringify(body), cache: 'no-store', credentials: 'omit' });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'This workspace request could not be completed.');
  return result;
}
function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function showError(id, message) { $(id).textContent = message || ''; $(id).hidden = !message; }
function dateLabel(value) { const date = new Date(value); return Number.isNaN(date.valueOf()) ? 'Time not recorded' : date.toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' }); }
function busyState(value) {
  busy = value;
  for (const button of document.querySelectorAll('#chat-form button, #investigations button, #new-chat, #settings-open, #stop-open, .suggestions button')) button.disabled = value;
  $('send').textContent = value ? 'Waiting…' : 'Send ↑';
}
function scrollToLatest() { const container = $('conversation-scroll'); container.scrollTop = container.scrollHeight; }

// Tenant and model content is always text; this small renderer never accepts HTML or links.
let responseTableCount = 0;
function inlineText(target, text) {
  for (const part of text.split(/(`[^`]+`|\*\*[^*]+\*\*|\*[^*\n]+\*)/g)) {
    const marker = /^`[^`]+`$/.test(part) ? ['code', 1] : /^\*\*[^*]+\*\*$/.test(part) ? ['strong', 2] : /^\*[^*\n]+\*$/.test(part) ? ['em', 1] : null;
    target.append(marker ? element(marker[0], part.slice(marker[1], -marker[1])) : document.createTextNode(part));
  }
}
function tableCells(line) {
  return line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '').split(/(?<!\\)\|/).map(cell => cell.trim().replace(/\\\|/g, '|'));
}
function richText(target, text) {
  let list, listType;
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  const nextContent = start => { while (start < lines.length && !lines[start].trim()) start++; return start; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) { list = null; continue; }
    const separator = nextContent(i + 1);
    const headers = tableCells(line);
    if (line.includes('|') && headers.length > 1 && headers.length <= 12 && headers.every(Boolean) && separator < lines.length) {
      const dividers = tableCells(lines[separator]);
      if (dividers.length === headers.length && dividers.every(cell => /^:?-{3,}:?$/.test(cell))) {
        list = null;
        const wrapper = element('div', undefined, 'response-table');
        wrapper.tabIndex = 0; wrapper.setAttribute('role', 'region');
        const table = element('table');
        const caption = element('caption', `Response table: ${headers.join(', ')}`, 'sr-only');
        caption.id = `response-table-${++responseTableCount}`;
        wrapper.setAttribute('aria-labelledby', caption.id);
        const head = element('thead'), headingRow = element('tr'), body = element('tbody');
        for (const header of headers) { const cell = element('th'); cell.scope = 'col'; inlineText(cell, header); headingRow.append(cell); }
        head.append(headingRow);
        let rowIndex = nextContent(separator + 1);
        i = separator;
        while (rowIndex < lines.length && lines[rowIndex].includes('|')) {
          const cells = tableCells(lines[rowIndex]);
          if (cells.length !== headers.length) break;
          const row = element('tr');
          cells.forEach((value, column) => { const cell = element(column === 0 ? 'th' : 'td'); if (column === 0) cell.scope = 'row'; inlineText(cell, value); row.append(cell); });
          body.append(row); i = rowIndex; rowIndex = nextContent(rowIndex + 1);
        }
        table.append(caption, head, body); wrapper.append(table); target.append(wrapper);
        continue;
      }
    }
    const bullet = /^\s*(?:([-*])|(\d{1,4})[.)])\s+/.exec(line);
    const type = bullet?.[2] ? 'ol' : 'ul';
    if (bullet && (!list || listType !== type)) { list = element(type); listType = type; if (type === 'ol') list.start = Number(bullet[2]); target.append(list); }
    if (!bullet) list = null;
    const node = element(bullet ? 'li' : /^#{1,3} /.test(line) ? 'h3' : 'p');
    inlineText(node, line.replace(bullet ? /^\s*(?:[-*]|\d{1,4}[.)])\s+/ : /^#{1,3} /, ''));
    (bullet ? list : target).append(node);
  }
}
function addMessage(role, content, note) {
  $('welcome').hidden = true;
  const article = element('article', undefined, `message ${role === 'user' ? 'user' : 'assistant'}`);
  const speaker = element('div', undefined, 'speaker');
  if (role !== 'user') { const mark = element('img'); mark.src = '/mark.svg'; mark.alt = ''; speaker.append(mark); }
  speaker.append(document.createTextNode(role === 'user' ? 'You' : 'Handoff'));
  const text = element('div', undefined, 'message-text');
  if (role === 'user') text.textContent = content; else richText(text, content);
  article.append(speaker, text);
  if (note) article.append(element('p', note, 'message-note'));
  $('messages').append(article);
  scrollToLatest();
  return article;
}
function renderList() {
  const query = $('search').value.toLocaleLowerCase();
  const items = config.items.filter(item => (item.name || '').toLocaleLowerCase().includes(query));
  $('item-count').textContent = config.items.length;
  $('investigations').replaceChildren();
  for (const item of items) {
    const button = element('button', undefined, 'investigation-button');
    button.type = 'button'; button.dataset.id = item.id; button.disabled = busy;
    button.setAttribute('aria-current', String(item.id === selected));
    button.append(element('strong', item.name || 'Group name not recorded'));
    const duplicate = config.items.filter(other => other.name === item.name).length > 1;
    button.append(element('small', `${item.sample ? 'Fictional sample' : 'Saved investigation'} · ${item.references} reference${item.references === 1 ? '' : 's'}${duplicate ? ` · ID ends ${item.groupId.slice(-8)}` : ''}`));
    button.addEventListener('click', () => void choose(item.id));
    $('investigations').append(button);
  }
  if (!items.length) $('investigations').append(element('p', 'No matching saved groups.', 'evidence-empty muted'));
}
function section(title) { const block = element('section', undefined, 'evidence-section'); block.append(element('h2', title)); $('evidence').append(block); return block; }
function technical(parent, title, value) { const details = element('details'); details.append(element('summary', title), element('pre', JSON.stringify(value, null, 2))); parent.append(details); }
function renderEvidence(report, sample) {
  $('evidence').replaceChildren();
  const coverage = section('Evidence coverage');
  const complete = report.coverage === 'complete_for_explicit_references';
  coverage.append(element('span', complete ? 'Complete for explicit references only' : 'Incomplete evidence', `coverage${complete ? '' : ' incomplete'}`));
  coverage.append(element('p', sample ? 'Fictional example. No tenant connection.' : `Saved ${dateLabel(report.collectedAt)}. Not current live state.`));
  coverage.append(element('p', 'Conditional Access and Intune device compliance. Other workloads and runtime access are not assessed.'));
  technical(coverage, 'Group identity & source details', { group: report.group, tenantId: report.tenantId, observationId: report.observationId, sources: report.sources });
  const relationships = section(`Recorded relationships (${report.references.length})`);
  if (!report.references.length) relationships.append(element('p', 'No explicit references were observed. This does not establish that the group is unused or safe to delete.'));
  for (const reference of report.references) {
    const policy = report.policyEvidence.find(p => p.evidenceId === reference.evidenceId);
    const block = element('div', undefined, 'relationship');
    block.append(element('h3', policy?.configuration?.displayName || 'Policy name not recorded'));
    const family = reference.source === 'conditionalAccess' ? 'Conditional Access' : 'Intune compliance';
    block.append(element('span', `${reference.relation === 'exclude' ? 'Excludes' : 'Includes'} this group · ${family}`, 'relation'));
    const states = { disabled: 'Disabled — configuration reference, not enforcement', enabledForReportingButNotEnforced: 'Report-only — not enforced', enabled: 'Enabled — applicability still needs verification' };
    if (policy?.configuration?.state) block.append(element('p', states[policy.configuration.state] || `Recorded state: ${policy.configuration.state}`));
    if (reference.filter?.id || reference.filter?.type) block.append(element('p', `Assignment filter: ${reference.filter.type || 'mode not recorded'}. Its name and rule were not collected.`));
    technical(block, 'View supporting evidence', { reference, configuration: policy?.configuration ?? 'Policy evidence not available' });
    relationships.append(block);
  }
  const checks = section('Before you make a change');
  const list = element('ul', undefined, 'manual-checks');
  for (const check of report.manualChecks) { const li = element('li'); li.append(element('strong', check.title)); const details = element('details'); details.append(element('summary', 'How to verify'), element('p', check.verify)); li.append(details); list.append(li); }
  checks.append(list);
  if (report.issues.length) { const issues = section('Recorded gaps'); for (const issue of report.issues) issues.append(element('p', `${issue.source || 'Evidence'}: ${issue.code}`)); }
}
async function choose(id) {
  if (busy) return;
  try {
    const data = await api('investigation', { id });
    selected = id;
    document.title = `${data.report.group.displayName || 'Group investigation'} | Handoff`;
    $('source-label').textContent = data.sample ? 'Fictional sample investigation' : 'Your saved group investigation';
    $('conversation-title').textContent = data.report.group.displayName || 'Selected group';
    $('selection-detail').textContent = `Recorded ${dateLabel(data.report.collectedAt)}. Ask about its policies and relationships, then follow up in the same conversation.`;
    $('messages').replaceChildren(); $('welcome').hidden = data.messages.length > 0;
    $('welcome-note').textContent = data.sample ? 'This sample is fictional. AI answers require your provider key and sharing approval.' : 'This is real saved tenant evidence. Nothing goes to an AI provider until you approve sharing.';
    for (const message of data.messages) addMessage(message.role, message.content, message.truncated ? 'The provider cut this answer short. Ask a more focused follow-up.' : undefined);
    $('question').value = ''; showError('chat-error', '');
    renderList(); renderEvidence(data.report, data.sample); updateSharingStatus(data.approved);
  } catch (error) { showError('notice', error.message); }
}
function updateSharingStatus(approved = false) {
  $('key-status').textContent = config.keyConfigured ? config.provider : 'Not set';
  $('sharing-status').textContent = !config.keyConfigured ? 'AI is optional. Add a provider key when you are ready to chat.' : approved ? `Sharing approved for this investigation with ${config.provider} / ${config.model}. Messages and evidence leave this computer when you Send. New conversation revokes approval.` : `${config.provider} / ${config.model}. You will review sharing before the first question is sent.`;
}
function settingsOpen() { $('provider').value = config.provider; $('model').value = config.model; $('api-key').value = ''; showError('settings-error', ''); $('settings').showModal(); }
async function cancelPrepared() {
  const cancelled = pending; pending = null;
  if (cancelled) { try { await api('cancel', { id: selected }); } catch { /* No send route is called on cancellation. */ } }
  busyState(false); $('question').focus();
}
async function sendPrepared(prepared, approveSharing) {
  pending = null;
  $('sharing').close();
  const question = $('question').value.trim();
  const user = addMessage('user', question);
  const waiting = element('p', 'Handoff is reading the saved evidence and your conversation…', 'message pending');
  $('messages').append(waiting); scrollToLatest();
  try {
    const result = await api('send', { id: selected, ticket: prepared.ticket, approveSharing });
    updateSharingStatus(true);
    waiting.remove();
    if (result.status !== 'answered') { user.remove(); throw new Error(failureMessages[result.failureCode] || 'The provider could not answer. No fallback provider was used.'); }
    addMessage('assistant', result.answer, result.truncated ? 'The provider cut this answer short. Ask a more focused follow-up.' : undefined);
    $('question').value = '';
    $('announcer').textContent = 'Handoff answered. The response is in the conversation.';
  } catch (error) { waiting.remove(); user.remove(); showError('chat-error', error.message); }
  finally { busyState(false); $('question').focus(); }
}
async function submitQuestion(event) {
  event.preventDefault();
  if (busy || !$('chat-form').reportValidity()) return;
  showError('chat-error', '');
  if (!selected) { showError('chat-error', 'Choose a saved investigation first.'); return; }
  if (!config.keyConfigured) { settingsOpen(); return; }
  busyState(true);
  try {
    const prepared = await api('prepare', { id: selected, question: $('question').value.trim() });
    if (prepared.approvalRequired) {
      pending = prepared;
      $('sharing-description').textContent = `Discuss “${prepared.name}” with ${prepared.sharing.provider}, model ${prepared.sharing.model}, at ${prepared.sharing.destination}. The prepared request is ${Math.ceil(prepared.sharing.bytes / 1024)} KB.`;
      $('payload').textContent = JSON.stringify(JSON.parse(prepared.technicalPayload), null, 2);
      $('sharing').showModal();
    } else await sendPrepared(prepared, false);
  } catch (error) { showError('chat-error', error.message); busyState(false); }
}

$('chat-form').addEventListener('submit', event => void submitQuestion(event));
$('question').addEventListener('keydown', event => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229) { event.preventDefault(); $('chat-form').requestSubmit(); }
});
$('search').addEventListener('input', renderList);
$('settings-open').addEventListener('click', settingsOpen);
$('home').addEventListener('click', event => { event.preventDefault(); $('question').focus(); });
for (const button of document.querySelectorAll('[data-close]')) button.addEventListener('click', () => $(button.dataset.close).close());
for (const button of document.querySelectorAll('[data-question]')) button.addEventListener('click', () => { $('question').value = button.dataset.question; $('question').focus(); });
$('provider').addEventListener('change', () => { $('model').value = $('provider').value === 'OpenAI' ? 'gpt-5' : 'claude-opus-5-5'; });
$('settings').addEventListener('close', () => { if (!$('settings').open) $('api-key').value = ''; });
$('settings-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = event.submitter || $('settings-form').querySelector('button[type="submit"]'); button.disabled = true;
  try {
    config = await api('provider', { provider: $('provider').value, model: $('model').value.trim(), apiKey: $('api-key').value.trim() });
    const draft = $('question').value;
    $('settings').close();
    if (selected) await choose(selected);
    $('question').value = draft; updateSharingStatus();
    $('announcer').textContent = 'AI settings are ready for this session. No evidence has been sent.';
  } catch (error) { showError('settings-error', error.message); }
  finally { $('api-key').value = ''; button.disabled = false; }
});
$('forget').addEventListener('click', async () => {
  try { config = await api('forget'); $('settings').close(); if (selected) await choose(selected); updateSharingStatus(); }
  catch (error) { showError('settings-error', error.message); }
});
$('sharing').addEventListener('close', () => { if (!$('sharing').open && pending) void cancelPrepared(); });
$('share-cancel').addEventListener('click', () => $('sharing').close());
$('share-approve').addEventListener('click', () => { if (pending) void sendPrepared(pending, true); });
$('new-chat').addEventListener('click', async () => { if (!selected || busy) return; try { await api('reset', { id: selected }); await choose(selected); $('question').focus(); } catch (error) { showError('chat-error', error.message); } });
$('stop-open').addEventListener('click', () => $('stop-dialog').showModal());
$('stop').addEventListener('click', async () => {
  try { await api('stop'); $('stop-dialog').close(); document.body.replaceChildren(element('main', 'Handoff is stopped. Your key and conversation have been forgotten. Saved investigations are unchanged. You can close this tab.', 'stopped')); }
  catch (error) { $('stop-dialog').close(); showError('notice', error.message); }
});

try {
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Open Handoff from its local launcher to authorise this workspace. Do not share its session URL.');
  config = await api('state'); renderList(); updateSharingStatus();
  if (config.warnings.length) showError('notice', config.warnings.join(' '));
  await choose(config.items[0].id);
  if (matchMedia('(max-width: 950px)').matches) $('evidence-disclosure').open = false;
  if (matchMedia('(max-width: 640px)').matches) document.querySelector('.investigation-navigation').open = false;
} catch (error) { showError('notice', error.message || 'The local workspace is no longer running. Reopen the launcher.'); }
