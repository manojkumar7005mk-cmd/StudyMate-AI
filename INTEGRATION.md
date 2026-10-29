# StudyMate v1.18 patch

Unzip this over the repo root. Existing files are replaced, new files are added.

    cd ~/StudyMate-AI
    unzip -o ~/StudyMate-v1.18-patch.zip -d .

Then make these changes by hand, since they depend on your current main.dart:

1. **Tabs (Instagram-style bottom bar).** In `MainShell.build`, replace the Scaffold with:

        return AppShell(tabs: [
          AppTab(label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home, page: HomePage(/* existing args */)),
          AppTab(label: 'Learn', icon: Icons.auto_awesome_outlined, selectedIcon: Icons.auto_awesome, page: TutorPage(/* existing args */)),
          AppTab(label: 'Planner', icon: Icons.event_note_outlined, selectedIcon: Icons.event_note, page: PlannerPage(/* existing args */)),
          AppTab(label: 'Notes', icon: Icons.sticky_note_2_outlined, selectedIcon: Icons.sticky_note_2, page: NotesPage()),
          AppTab(label: 'Models', icon: Icons.memory_outlined, selectedIcon: Icons.memory, page: ModelsPage(/* existing args */)),
        ]);

   Calendar, Progress and Settings go on a "More" page that lists them as tiles. Add `import 'ui/app_shell.dart';`.

2. **Models page.** Replace the file list in `ModelsPage` with `ModelDownloadPanel(manager: ModelManager())`. This shows one card per model, so the vision projector no longer appears as a second chat model. This is the likely cause of the two-model error in the Windows app.

3. **Hashtags.** In `TutorPage` send logic:

        final plan = HashtagRouter.parse(text);     // import 'core/hashtag_router.dart';
        // send plan.cleanText, add plan.instruction to the system prompt,
        // and use plan.maxTokens as the generation limit.

4. **Android engine.** Where the chat calls `LlamaService`, use `AndroidLlm` when `Platform.isAndroid`:

        final llm = AndroidLlm();
        await llm.load(modelPath);
        final prompt = buildChatMl(system: tutorSystemPrompt, history: history, user: plan.cleanText + ' ' + plan.instruction);
        await for (final piece in llm.generate(prompt, maxTokens: plan.maxTokens)) { /* append to bubble */ }

5. **Windows/Linux workflow.** In `.github/workflows/windows-build.yml`, add this at the top level to remove the Node 20 warnings:

        env:
          FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: 'true'

6. **Android.** The GitHub workflow `android-build.yml` creates the Android folder, runs `scripts/patch_android.py`, clones llama.cpp into `android/app/src/main/cpp/llama.cpp`, and builds the APK. Download it from the run's Artifacts as `StudyMate-AI-Android-APK`.

Testing: run `flutter test` locally, or check the CI log for `Analyze`. Expect a few compile fixes on the first run.
