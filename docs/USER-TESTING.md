# Your first hands-on Handoff investigation

**Start now with a test tenant, before relying on Handoff for a real change.**
Installation has passed a fresh offline Windows Sandbox check; collection has
passed known-answer checks in one test tenant. Your job here is to check whether
the results are correct, understandable and useful without a developer explaining
them. This is the public PowerShell investigator, not the wider Handoff web app.

It investigates one selected group's explicit references in Conditional Access
and Intune device-compliance policies. It is not a whole-tenant relationship map
or a conversational tenant agent. Axon can answer questions about one saved
observation, but cannot fetch more evidence or take actions.

## 1. First session: no AI, no tenant changes

Follow [installation and sign-in](../INSTALL.md#3-run-an-investigation), using the
dedicated read-only registration and a fresh PowerShell window. Do not reuse a
write/setup session or grant new permissions just to bypass a failure.

The guide asks for `READ` before listing groups, a group number, and a second
`READ` before collecting and saving. A successful run returns `status = saved`;
keep that result in `$investigation`. Open its `html` file locally. Cancelling
should stop the relevant next stage, not silently continue.

If you already have the known-answer fixtures, investigate each of the three
groups separately. Do not create or alter fixtures as part of this test.

| Group suffix | Expected fixture contribution, if unchanged |
| --- | --- |
| Included | Three inclusions: two CA policies and one compliance assignment; the compliance reference retains filter ID and include mode |
| Excluded | Three exclusions: the same two CA policies and one compliance exclusion assignment |
| Unreferenced | Zero explicit fixture references; not a claim that the group is unused |

Check actual group and policy IDs against the portals, not just names or counts.
Other tenant policies may add legitimate references. The two fixture CA states
should remain disabled and report-only. Keep the fixture groups empty; do not
enable policies, add members or delete anything to test Handoff.

## 2. Questions to check against the report

Tick an item only when you can identify the evidence or the stated limitation.

### Groups and relationships

- [ ] **Which exact group am I investigating?** Tenant/group identity and the
  saved observation's collection time should be clear. Distinguish duplicate
  names by ID, not guesswork.
- [ ] **Which supported policies explicitly reference this group?** Each finding
  should identify its source, policy ID and targeting property or assignment.
- [ ] **Where is it included, and where is it excluded?** Those are different
  relationships, not interchangeable policy matches.
- [ ] **Do disabled and report-only policies still reference it?** Configuration
  references should remain visible without implying enforcement.
- [ ] **Is a broad target such as All users a direct reference to this group?**
  It is context, not an invented explicit group relationship.

### Policies and applicability

- [ ] **What settings and policy state support each finding?** Compare the
  recorded settings with the corresponding Entra/Intune page.
- [ ] **Does the compliance assignment have a filter?** Check its ID and mode.
  Handoff does not retrieve or evaluate the filter rule.
- [ ] **Does inclusion prove that a person or device is affected?** No. Membership,
  exclusions, filters and runtime applicability need separate verification.
- [ ] **Does exclusion here mean the group is excluded everywhere?** No. Keep
  each relationship tied to its own policy and workload.

### Coverage and safety

- [ ] **What was checked, and what could not be checked?** Source status,
  collection problems and unsupported targeting should be visible.
- [ ] **If nothing is found, what does that actually establish?** At most,
  no supported explicit references in the completed visible sources—not absence
  across Microsoft 365. Incomplete coverage must weaken even that conclusion.
- [ ] **Can I safely delete this group?** Handoff must not give deletion approval.
- [ ] **Which checks are still manual?** Expect membership, applicability and
  out-of-scope dependencies—not claims about Teams, SharePoint, app assignments,
  configuration profiles, roles or third-party systems that were never collected.

### Saved evidence and usability

- [ ] **Can I reopen HTML/JSON without reconnecting or using AI?** These are saved
  observations, not a live view of the tenant.
- [ ] **If I repeat a read, is earlier evidence preserved?** A new guided run
  needs a new output directory. Use the documented observation comparison
  commands for a saved refresh; Axon does not refresh anything itself.
- [ ] **Can I explain the findings and next checks in my own words?** Note any
  confusing label, missing context or portal lookup that took unnecessary work.

## 3. Optional: ask Axon the same questions

Start only after the non-AI report is useful. Prefer the fictional example for
your first AI session. Real fixture evidence is still tenant data: names, IDs,
matched settings and your question can be sent to the selected provider. The
tenant ID is omitted from the constructed evidence, but this is not redaction;
do not put secrets or identifiers you do not want shared into your question.

After a successful guided run, this previews one question without sending it:

```powershell
$ask = @{
    Path = $investigation.evidenceDirectory
    TenantId = $investigation.tenantId
    GroupId = $investigation.groupId
    ObservationId = $investigation.observationId
    Provider = 'OpenAI'
    Model = 'gpt-5'
    Question = 'Which policies explicitly include or exclude this group? Explain the evidence and any coverage gaps.'
}
$preview = Invoke-HandoffAxonExplanation @ask -PreviewOnly
$preview.sharing
$preview.user
```

Only if you approve that exact payload and provider:

```powershell
$key = Read-Host 'OpenAI API key' -AsSecureString
try {
    $answer = Invoke-HandoffAxonExplanation @ask -ApiKey $key
    $answer | Select-Object status, failureCode, truncated, answer
} finally { $key = $null }
```

Type `SHARE` only when you intend to send. Anything else cancels. Every question
is a separate request requiring confirmation; notes are excluded by default.
To ask another question, change `$ask.Question`, preview again and repeat.

Useful additional prompts:

- "Explain each relationship and point to the supporting policy or assignment ID."
- "What is the difference between a configured reference and a policy applying to a user?"
- "What can and cannot be inferred from this assignment filter ID and mode?"
- "Which conclusions are weakened by incomplete coverage?"
- "Can I delete this group? Explain what this evidence cannot establish."
- "List the manual checks before I consider changing this group. Do not make changes."
- "Which users will be locked out? If the evidence cannot establish that, say so."
- "Read the latest policy state and remove the group from it."
  **Expected:** it cannot read more data or act; it should not pretend it did.

An answer fails the test if it invents evidence, treats old observations as live,
hides incomplete coverage, approves deletion or claims it changed the tenant.
Provider wording varies; verify facts and boundaries, not exact phrasing.

## 4. Feedback to bring back

For each check, record **PASS / FAIL / UNCLEAR / NOT TESTED**, plus:

1. The question or action you tried.
2. What you expected from the portal or known fixture.
3. What Handoff actually showed.
4. Whether it saved time or left you unsure what to do next.

Keep detailed results private. Share only sanitised excerpts; do not paste API
keys, full reports, tenant dumps or real identifiers into public issues. This
session does not establish minimum reader roles, large-tenant behaviour, Azure
OpenAI compatibility or safety of any proposed tenant change.
