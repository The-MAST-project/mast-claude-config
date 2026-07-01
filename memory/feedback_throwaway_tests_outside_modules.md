---
name: feedback-throwaway-tests-outside-modules
description: "For throwaway assessments / one-off comparison scripts, put all files in a new standalone directory under C:\\MAST — never inside existing source modules."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: caa181a7-2394-4222-9dea-66b2b9161d14
---

For throwaway assessments and one-off comparison/equivalence scripts, create a new standalone directory under `C:\MAST\` (e.g. `C:\MAST\<assessment-name>\`) and put **all** test artifacts there. Do not place them under `MAST_unit.*/src/...` or any existing module tree, and do not nest under `C:\MAST\tmp\` either — pick a clear top-level throwaway dir name.

**Why:** Keeps experimental code clearly separated from production modules so it's obvious what's throwaway and easy to delete wholesale when the assessment is done. Avoids polluting the real source tree with one-off scripts.

**How to apply:** When planning any ad-hoc test, benchmark, or equivalence check, default the working directory to `C:\MAST\<descriptive-name>\` and put the script, its outputs, and any generated FITS/JSON/text reports there. Only deviate if the user explicitly asks for integration into an existing module.
