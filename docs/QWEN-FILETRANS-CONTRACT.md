# Qwen file transcription contract

Official documentation checked 2026-11-18 (Asia/Shanghai), without paid requests:

- https://help.aliyun.com/zh/model-studio/qwen-audio-asr-filetrans-http-api
- https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide

Model: qwen-audio-3.1-asr-flash-filetrans. Requests send one input.file_urls entry, parameters.channel_id [0], and parameters.diarization_enabled. Diarization requires mono. Documented sentences[].speaker_id is a task-local integer starting at zero; string IDs are tolerated. Missing IDs stay unassigned. Sentence begin/end times are milliseconds. Untimed text fails instead of receiving invented timestamps.

Workspace endpoints: https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1 and https://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api/v1. Existing configurations can still use legacy regional DashScope hosts. Upload-policy requests use the regional DashScope host. Keys/workspace/model access must share a region. Documentation does not verify an individual account's model access; service failures are surfaced.

The file-model specification permits up to 2 GB / 12 hours, including WAV, M4A and MP3. Input is normalized to 16 kHz mono 16-bit PCM WAV. An independent 120-minute product guard for diarization follows the official two-hour recommendation. Speaker tasks are never silently split. Recorded meetings without diarization use legacy chunks; imports remain file sessions.

Temporary upload URLs expire after 48 hours. Task queries/results have a 24-hour window; saved sessions past it require explicit new submission. Request and polling waits are bounded; longer session polling backs off and respects bounded Retry-After seconds. Ending a local wait does not cancel accepted work or charges. Ambiguous submissions never repost automatically.

Production multipart bodies are file-backed and URLSession uploads from file, with bounded memory. Signed storage requests receive no API key. Small mock fixtures cover upload/submission/checkpoints, sentence timing, speaker IDs, no-speech, task resumption, task-scoped identities, usage and public-output redaction.
