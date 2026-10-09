# 0004 — Uitrollen gebeurt vanaf main, op de productiemachine

**Aanleiding.** Een push naar `main` moet zonder handwerk live komen, en alleen
als hij de controles haalt.

**Besluit.** De CI draait op GitHub-machines. Slaagt hij voor een push naar `main`
van deze repo, dan start de workflow `Deploy` op een self-hosted runner op VM102,
die bouwt en uitrolt met `build-prod.sh`, `deploy-prod.sh` en
`deploy-frontend.sh`. De secrets staan in `.env.prod` op die machine en komen
nooit in GitHub. De agents op de nodes werken zichzelf daarna bij, in golven
(`Fleet.AgentUpdate`).

**Waarom.** Geen secrets in GitHub, geen tussenstap die een mens kan vergeten, en
een uitrol die alleen gebeurt na een groene CI.

**Wat erbij hoort.**
- De repo is openbaar. De uitrol mag daarom ALLEEN starten voor een `push` naar
  `main` uit deze repo zelf; een pull request uit een fork met een branch die
  "main" heet, mocht dat eerder ook (gedicht op 2026-10-09). Handmatig starten
  mag alleen vanaf `main`.
- VM102 heeft twee cores. Een bouw naast een testronde laat buildkit omvallen;
  `gate2.sh` en `testfiles.sh` weigeren daarom te starten zolang de runner een
  job draait.

**Alternatieven.** Een registry plus pull vanaf de machine (geen bouw op de
productiemachine, wel een registry en een token om te beheren); handmatig
uitrollen (vergeten stappen, geen gate).

**Gevolgen.** Bouwen kost productie CPU. Een aparte bouwmachine is de volgende
stap als het platform groeit.
