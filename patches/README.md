# patches/

Reserved for .patch files to apply when we don't fork a submodule but need
a small code tweak. Currently empty — Patch #1 (helpers.rb) lives as a
commit on whitelionred/evo-ai-crm-community@local-fixes instead.

If you add a patch here, the workflow is:

    git format-patch -1 -o ../evo-crm-community/patches HEAD

and then reapply with:

    git -C <submodule> apply ../patches/xxxx.patch

Document each patch in CUSTOMIZATIONS.md.
