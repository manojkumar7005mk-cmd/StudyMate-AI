# StudyMate AI — Windows desktop

StudyMate AI is a student-friendly learning companion built with Flutter. This project combines the supplied Google Stitch screen concepts (welcome, student details, education setup, goals, routine, dashboard, tutor chat, notes, calendar and progress) with an editable daily timetable, locally saved notes/profile and a local llama.cpp chat server.

## What works in this version

- Student profile onboarding/editing: name, board, class/year, subjects, goals and study routine.
- Home dashboard with today's timetable and quick navigation.
- Planner: a weekly class timetable, test dates with countdowns, a button to push the next 7 days of classes into the calendar, a button to add revision sessions before a test, and a Reminders tab (tests 8 days ahead, sessions today and tomorrow).
- Day-by-day calendar, create/delete sessions, and mark sessions completed.
- Notes: create, search, read and delete; save AI responses to notes.
- Progress dashboard for planned/completed sessions and saved notes.
- Light/dark theme and privacy information.
- Model file discovery/download from the Hugging Face model repository, `.part` resume support, progress indicator and file-size verification.
- Local llama.cpp server startup/health check and local chat API; Windows server binaries are added by GitHub Actions.
- Windows built-in text-to-speech for tutor responses.

**Current implementation notes:** timetable reminders are shown in the app calendar/home view; native Windows toast scheduling, live microphone conversation, webcam/screenshot/image/audio multimodal chat, clipboard image paste, and full SSE streaming are not implemented in this initial package. The chat currently sends non-streaming text requests to the local server. Keep the model repository/license and runtime requirements in mind before distributing model files; this project intentionally does not package model weights.

## Prerequisites for local development

- Flutter stable with Windows desktop enabled
- Visual Studio 2022 with the **Desktop development with C++** workload
- Windows 10/11

Run in PowerShell from the project folder:

```powershell
flutter config --enable-windows-desktop
flutter create --platforms=windows .
flutter pub get
flutter run -d windows
```

## Push this project to GitHub using CMD

1. Extract `StudyMate-AI-Project.zip` to a folder, for example `C:\Users\YOURNAME\Desktop\StudyMate-AI`.
2. Create an empty repository on GitHub (do not add a README if you want the commands below unchanged).
3. Open **Command Prompt (CMD)** and run:

```bat
cd /d "%USERPROFILE%\Desktop\StudyMate-AI"
git init
git branch -M main
git add .
git commit -m "Create StudyMate AI desktop app"
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

Replace `YOUR_GITHUB_USERNAME` and `YOUR_REPOSITORY` with your actual GitHub details. Git and GitHub authentication must be set up on your computer.

## Download the built app without installing Flutter locally

1. Push the code to GitHub.
2. Open the repository's **Actions** tab.
3. Select **Build StudyMate AI for Windows** and wait for the workflow to finish successfully.
4. Open the completed run and scroll to **Artifacts**.
5. Download `StudyMate-AI-Windows` (ZIP) or `StudyMate-AI-Setup` (installer).
6. Extract the ZIP and run `studymate_ai.exe`, or run the setup installer.

A tagged push such as `v1.0.0` also attempts to create a GitHub Release with both build files attached.

## First run

1. Complete the student profile form.
2. Open **Models** and download the model files. This download requires internet and can be several gigabytes.
3. If the download fails, retry; partial `.part` files are resumed when the server supports HTTP Range.
4. Select **Load model**. The packaged `bin\llama-server.exe` and its required DLLs must be next to the app executable.
5. Open **Learn** and ask a question. Once model files are downloaded, inference is local.
6. Use **Calendar** to add sessions for each date and **Notes** to save revision material.

## Troubleshooting

- **Not enough RAM / model fails to load:** close other applications and try Models → Low-memory mode. A 3B multimodal model may need roughly 5–6 GB free RAM depending on quantization and runtime.
- **Antivirus blocks `llama-server.exe`:** verify the downloaded CI artifact/release came from your repository. Follow your institution's or device administrator's process for reviewing a flagged binary; do not disable protection blindly.
- **Microphone permission:** microphone capture is not implemented in this initial version. Windows microphone permission is not needed for current text-only chat.
- **Firewall asks about localhost:** the local server listens on `127.0.0.1` only. Allowing local loopback is normally sufficient; do not expose the server to public networks.
- **No model download / offline first launch:** download model files while connected to the internet once. The model is deliberately not included in the build artifact.
- **Build fails in Actions:** open the workflow run and inspect the `Analyze`, `Build release`, and `Download llama.cpp` logs. The upstream llama.cpp release asset naming can change over time; the workflow reports an explicit error if no matching Windows x64 CPU ZIP exists.
- **Git says command not found:** install Git for Windows, reopen CMD and retry.

## Data and privacy

Student profile, sessions and notes are stored in the app's local preferences on this PC. The app downloads model files from Hugging Face when requested. Text chat is sent only to the local llama.cpp server started on loopback by this application.

## Design reference

The `design_reference/stitch_studymate_ai_learning_companion/` folder includes the supplied Stitch HTML and screenshots so the original UI concepts remain available while you customize the Flutter implementation.
