/// Generated from api/openapi.yaml by scripts/sync-openapi.sh; a test keeps them equal.
let openAPISpec = #"""
openapi: 3.1.0
info:
  title: LocalHub
  version: 0.1.0
  summary: This Mac's local AI apps as one paired, certificate-pinned service.
  description: |
    Pair once (`POST /v2/pair`, code from the Mac), pin the certificate's SHA-256 (the invite's `fp`)
    and send `Authorization: Bearer <token>`. OpenAI-compatible where OpenAI has an equivalent.
    Errors are `{"error": {"code", "message", "provider"?}}`. See the repository README for client setup.
servers:
  - url: https://{host}:{port}
    variables:
      host: { default: 127.0.0.1 }
      port: { default: "8790" }
security:
  - device: []
tags:
  - name: Pairing
  - name: Chat
  - name: Images
  - name: Audio
  - name: Video
  - name: 3D
  - name: Files
  - name: Jobs
  - name: Hub
  - name: MCP
paths:
  /v2/hub:
    get:
      tags: [Hub]
      summary: Hub identity (no token needed)
      security: []
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/HubInfo" } } } }
  /v2/openapi.yaml:
    get:
      tags: [Hub]
      summary: This document (no token needed)
      security: []
      responses:
        "200": { description: OK, content: { application/yaml: {} } }
  /v2/pair:
    post:
      tags: [Pairing]
      summary: Exchange the one-time code for a device token
      security: []
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/PairRequest" } } }
      responses:
        "200": { description: Paired, content: { application/json: { schema: { $ref: "#/components/schemas/PairResult" } } } }
        "401": { $ref: "#/components/responses/Error" }
        "410": { $ref: "#/components/responses/Error" }
        "429": { $ref: "#/components/responses/Error" }
  /v2/session:
    get:
      tags: [Pairing]
      summary: This device and its permissions
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/Session" } } } }
    delete:
      tags: [Pairing]
      summary: Unpair this device
      responses:
        "204": { description: Unpaired }
  /v2/events:
    get:
      tags: [Hub]
      summary: Server-sent events for this device
      description: "`event: job` (Job), `event: session` (Session, permissions changed), `event: revoked` (stream ends). `: ping` every 25 s."
      responses:
        "200": { description: Event stream, content: { text/event-stream: {} } }
  /v2/profiles:
    get:
      tags: [Hub]
      summary: Published work profiles with model defaults filtered by device permissions
      responses:
        "200": { description: Work profiles, content: { application/json: { schema: { type: array, items: { $ref: "#/components/schemas/WorkProfile" } } } } }
        default: { $ref: "#/components/responses/Error" }
  /v2/integrations:
    get:
      tags: [Hub]
      summary: Apps this device may use and whether they are running
      responses:
        "200":
          description: OK
          content: { application/json: { schema: { type: array, items: { $ref: "#/components/schemas/Integration" } } } }
  /v1/models:
    get:
      tags: [Chat]
      summary: Models and workflows this device may use
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                type: object
                properties:
                  object: { const: list }
                  data: { type: array, items: { $ref: "#/components/schemas/Model" } }
  /v1/chat/completions:
    post:
      tags: [Chat]
      summary: "OpenAI chat completions (stream with `stream: true`)"
      description: |
        Body is OpenAI's; `model` is a hub id such as `lmstudio/qwen/qwen3-8b`. Extension: `mcp_servers: ["files"]`
        lets the hub run those MCP tools for the model (the reply then carries `localhub_tool_calls`).
        Closing a streamed response cancels the generation.
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [messages]
              properties:
                model: { type: string }
                profile: { type: string, description: "Work profile ID. Omitted uses the device preference; empty string disables it. Explicit model wins over the profile." }
                messages: { type: array, items: { type: object } }
                stream: { type: boolean }
                mcp_servers: { type: array, items: { type: string }, maxItems: 8 }
              additionalProperties: true
      responses:
        "200":
          description: "Completion, or `text/event-stream` chunks ending with `data: [DONE]`"
          content: { application/json: { schema: { type: object } }, text/event-stream: {} }
        default: { $ref: "#/components/responses/Error" }
  /v1/embeddings:
    post:
      tags: [Chat]
      summary: OpenAI embeddings
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [input]
              properties:
                model: { type: string }
                input: { oneOf: [{ type: string }, { type: array, items: { type: string } }] }
                profile: { type: string }
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object } } } }
        default: { $ref: "#/components/responses/Error" }
  /v1/images/generations:
    post:
      tags: [Images]
      summary: "Create an image (waits; `Prefer: respond-async` returns a job)"
      parameters: [{ $ref: "#/components/parameters/Prefer" }]
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/MediaRequest" } } }
      responses:
        "200": { $ref: "#/components/responses/Media" }
        "202": { $ref: "#/components/responses/Accepted" }
        default: { $ref: "#/components/responses/Error" }
  /v1/images/edits:
    post:
      tags: [Images]
      summary: Edit an image (inpaint); mask meaning follows the Mac's workflow
      parameters: [{ $ref: "#/components/parameters/Prefer" }]
      requestBody:
        required: true
        content:
          multipart/form-data: { schema: { $ref: "#/components/schemas/MediaUpload" } }
          application/json: { schema: { $ref: "#/components/schemas/MediaRequest" } }
      responses:
        "200": { $ref: "#/components/responses/Media" }
        "202": { $ref: "#/components/responses/Accepted" }
        default: { $ref: "#/components/responses/Error" }
  /v1/audio/speech:
    post:
      tags: [Audio]
      summary: Speak text; returns the audio bytes
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required: [input]
              properties: { input: { type: string }, model: { type: string }, voice: { type: string }, profile: { type: string } }
      responses:
        "200": { description: Audio, content: { audio/flac: {}, audio/wav: {}, audio/mpeg: {} } }
        default: { $ref: "#/components/responses/Error" }
  /v1/audio/generations:
    post:
      tags: [Audio]
      summary: Create music or sound effects (extension)
      parameters: [{ $ref: "#/components/parameters/Prefer" }]
      requestBody:
        required: true
        content: { application/json: { schema: { $ref: "#/components/schemas/MediaRequest" } } }
      responses:
        "200": { $ref: "#/components/responses/Media" }
        "202": { $ref: "#/components/responses/Accepted" }
        default: { $ref: "#/components/responses/Error" }
  /v1/audio/edits:
    post:
      tags: [Audio]
      summary: Edit audio (extension)
      parameters: [{ $ref: "#/components/parameters/Prefer" }]
      requestBody:
        required: true
        content: { multipart/form-data: { schema: { $ref: "#/components/schemas/MediaUpload" } } }
      responses:
        "200": { $ref: "#/components/responses/Media" }
        "202": { $ref: "#/components/responses/Accepted" }
        default: { $ref: "#/components/responses/Error" }
  /v1/audio/transcriptions:
    post:
      tags: [Audio]
      summary: Transcribe audio (whisper.cpp or an OpenAI-style server on the Mac)
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [file]
              properties:
                file: { type: string, format: binary }
                model: { type: string, description: "`<integration>/<model>`, e.g. `speaches/large-v3`" }
                profile: { type: string, description: "Work profile ID; empty disables the device default" }
                language: { type: string }
                prompt: { type: string }
                response_format: { enum: [json, text, srt, vtt, verbose_json] }
      responses:
        "200": { description: "`{text}` or plain text", content: { application/json: { schema: { type: object, properties: { text: { type: string } } } }, text/plain: {} } }
        default: { $ref: "#/components/responses/Error" }
  /v1/videos:
    post:
      tags: [Video]
      summary: Create a video (always asynchronous)
      requestBody:
        required: true
        content:
          application/json: { schema: { $ref: "#/components/schemas/MediaRequest" } }
          multipart/form-data: { schema: { $ref: "#/components/schemas/MediaUpload" } }
      responses:
        "200": { description: Queued, content: { application/json: { schema: { $ref: "#/components/schemas/Video" } } } }
        default: { $ref: "#/components/responses/Error" }
    get:
      tags: [Video]
      summary: This device's videos
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object, properties: { data: { type: array, items: { $ref: "#/components/schemas/Video" } } } } } } }
  /v1/videos/{id}:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Video]
      summary: Video status
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/Video" } } } }
        "404": { $ref: "#/components/responses/Error" }
    delete:
      tags: [Video]
      summary: Cancel if running and delete the video and its file
      responses:
        "200": { description: Deleted, content: { application/json: { schema: { $ref: "#/components/schemas/Deleted" } } } }
  /v1/videos/{id}/content:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Video]
      summary: The finished video
      responses:
        "200": { description: Video bytes, content: { video/mp4: {}, video/webm: {} } }
        "409": { $ref: "#/components/responses/Error" }
  /v1/videos/{id}/remix:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    post:
      tags: [Video]
      summary: Edit a finished video with a new prompt
      requestBody:
        required: true
        content: { application/json: { schema: { type: object, required: [prompt], properties: { prompt: { type: string }, model: { type: string } } } } }
      responses:
        "200": { description: Queued, content: { application/json: { schema: { $ref: "#/components/schemas/Video" } } } }
        default: { $ref: "#/components/responses/Error" }
  /v1/3d/generations:
    post:
      tags: [3D]
      summary: Create a 3D model (GLB) from an image and/or text (extension)
      parameters: [{ $ref: "#/components/parameters/Prefer" }]
      requestBody:
        required: true
        content:
          multipart/form-data: { schema: { $ref: "#/components/schemas/MediaUpload" } }
          application/json: { schema: { $ref: "#/components/schemas/MediaRequest" } }
      responses:
        "200": { $ref: "#/components/responses/Media" }
        "202": { $ref: "#/components/responses/Accepted" }
        default: { $ref: "#/components/responses/Error" }
  /v1/files:
    post:
      tags: [Files]
      summary: Upload a file
      requestBody:
        required: true
        content:
          multipart/form-data:
            schema:
              type: object
              required: [file]
              properties: { file: { type: string, format: binary }, purpose: { type: string, maxLength: 32 } }
      responses:
        "200": { description: Stored, content: { application/json: { schema: { $ref: "#/components/schemas/File" } } } }
        "413": { $ref: "#/components/responses/Error" }
        "415": { $ref: "#/components/responses/Error" }
    get:
      tags: [Files]
      summary: This device's files
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object, properties: { data: { type: array, items: { $ref: "#/components/schemas/File" } } } } } } }
  /v1/files/{id}:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Files]
      summary: File metadata
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/File" } } } }
        "404": { $ref: "#/components/responses/Error" }
    delete:
      tags: [Files]
      summary: Delete a file
      responses:
        "200": { description: Deleted, content: { application/json: { schema: { $ref: "#/components/schemas/Deleted" } } } }
  /v1/files/{id}/content:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Files]
      summary: File bytes
      responses:
        "200": { description: Bytes }
        "404": { $ref: "#/components/responses/Error" }
  /v1/jobs:
    get:
      tags: [Jobs]
      summary: This device's recent jobs
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object, properties: { data: { type: array, items: { $ref: "#/components/schemas/Job" } } } } } } }
  /v1/jobs/{id}:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Jobs]
      summary: Job status
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/Job" } } } }
        "404": { $ref: "#/components/responses/Error" }
  /v1/jobs/{id}/events:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Jobs]
      summary: "SSE: `event: progress` updates, then `completed`, `failed` or `cancelled`"
      responses:
        "200": { description: Event stream of Job objects, content: { text/event-stream: {} } }
  /v1/jobs/{id}/preview:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Jobs]
      summary: Latest live preview frame while running (when the Job's `has_preview` is true)
      responses:
        "200": { description: Image, content: { image/jpeg: {}, image/png: {} } }
        "404": { $ref: "#/components/responses/Error" }
  /v1/jobs/{id}/cancel:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    post:
      tags: [Jobs]
      summary: Cancel (only this job is stopped in ComfyUI)
      responses:
        "200": { description: OK, content: { application/json: { schema: { $ref: "#/components/schemas/Job" } } } }
  /v1/jobs/{id}/recipe:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    get:
      tags: [Jobs]
      summary: Production recipe for an owned job, without the private workflow graph
      responses:
        "200": { description: Resolved parameters and input references, content: { application/json: { schema: { $ref: "#/components/schemas/Recipe" } } } }
        "404": { $ref: "#/components/responses/Error" }
  /v1/jobs/{id}/replay:
    parameters: [{ $ref: "#/components/parameters/Id" }]
    post:
      tags: [Jobs]
      summary: Replay a finished owned job with its saved parameters
      description: Requires the capability permission and a still-published matching workflow version. Variations replace only the mapped seed. A new queued job is returned. Legacy jobs and deleted input files cannot be replayed.
      requestBody:
        required: true
        content:
          application/json:
            schema: { type: object, properties: { variation: { type: boolean, default: false } } }
      responses:
        "200": { description: New job, content: { application/json: { schema: { $ref: "#/components/schemas/Job" } } } }
        "403": { $ref: "#/components/responses/Error" }
        "404": { $ref: "#/components/responses/Error" }
        "409": { $ref: "#/components/responses/Error" }
        "429": { $ref: "#/components/responses/Error" }
  /v2/mcp/servers:
    get:
      tags: [MCP]
      summary: MCP servers this device may use
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: array, items: { type: object, properties: { id: { type: string }, transport: { type: string }, allowedTools: { type: array, items: { type: string } } } } } } } }
  /v2/mcp/{server}/tools:
    parameters: [{ name: server, in: path, required: true, schema: { type: string } }]
    get:
      tags: [MCP]
      summary: The server's allowed tools with their input schemas
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object, properties: { tools: { type: array, items: { type: object } } } } } } }
  /v2/mcp/{server}/call:
    parameters: [{ name: server, in: path, required: true, schema: { type: string } }]
    post:
      tags: [MCP]
      summary: Call an allowed tool (arguments are checked against its schema)
      requestBody:
        required: true
        content: { application/json: { schema: { type: object, required: [name, arguments], properties: { name: { type: string }, arguments: { type: object } } } } }
      responses:
        "200": { description: OK, content: { application/json: { schema: { type: object, properties: { content: { type: array, items: { type: object } }, isError: { type: boolean } } } } } }
        "400": { $ref: "#/components/responses/Error" }
        "403": { $ref: "#/components/responses/Error" }
components:
  securitySchemes:
    device:
      type: http
      scheme: bearer
      description: The token from `POST /v2/pair`. Only over a connection whose certificate SHA-256 matches the pinned fingerprint.
  parameters:
    Id: { name: id, in: path, required: true, schema: { type: string } }
    Prefer:
      name: Prefer
      in: header
      required: false
      schema: { const: respond-async }
      description: Return `202` with a Job instead of waiting for the result.
  responses:
    Error:
      description: Error
      content: { application/json: { schema: { $ref: "#/components/schemas/Error" } } }
    Media:
      description: Result files
      content:
        application/json:
          schema:
            type: object
            properties:
              created: { type: integer }
              data:
                type: array
                items:
                  type: object
                  properties: { b64_json: { type: string }, url: { type: string }, file_id: { type: string } }
    Accepted:
      description: Queued job
      content: { application/json: { schema: { $ref: "#/components/schemas/Job" } } }
  schemas:
    Error:
      type: object
      properties:
        error:
          type: object
          required: [code, message]
          properties:
            code:
              type: string
              examples: [unauthorized, forbidden, provider_unavailable, provider_timeout, model_not_found, capability_unavailable,
                         too_many_jobs, job_failed, job_cancelled, not_ready, quota_exceeded, payload_too_large,
                         unsupported_media_type, bad_request, wrong_code, pairing_closed, too_many_attempts, insufficient_memory,
                         model_unsupported]
            message: { type: string }
            provider: { type: string }
    HubInfo:
      type: object
      properties: { service: { const: localhub }, version: { type: string }, protocolVersion: { type: integer }, id: { type: string }, name: { type: string } }
    PairRequest:
      type: object
      required: [code, deviceName, app]
      properties:
        code: { type: string, pattern: "^\\d{6}$" }
        deviceName: { type: string, minLength: 1, maxLength: 80 }
        app: { type: string, minLength: 1, maxLength: 64 }
        scopes: { type: array, items: { $ref: "#/components/schemas/Scope" } }
    PairResult:
      type: object
      properties: { deviceID: { type: string }, token: { type: string }, scopes: { type: array, items: { $ref: "#/components/schemas/Scope" } } }
    Session:
      type: object
      properties: { deviceID: { type: string }, name: { type: string }, app: { type: string }, scopes: { type: array, items: { $ref: "#/components/schemas/Scope" } } }
    Scope:
      type: string
      description: A capability or `mcp:<server>`.
      examples: [chat, embeddings, image.create, image.edit, audio.speech, audio.create, audio.edit, audio.transcribe, video.create, video.edit, 3d.create, "mcp:files"]
    Integration:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        kind: { enum: [openai, comfyui, whisper] }
        state: { enum: [running, unreachable, error] }
        capabilities: { type: array, items: { type: string } }
        models: { type: integer }
        detail: { type: string }
    Model:
      type: object
      properties:
        id: { type: string, examples: ["lmstudio/qwen/qwen3-8b", "comfyui/sdxl-inpaint"] }
        object: { const: model }
        owned_by: { type: string }
        provider: { type: string }
        upstream_id: { type: string }
        capabilities: { type: array, items: { $ref: "#/components/schemas/Scope" } }
        loaded: { type: boolean, description: "LM Studio only: in memory" }
    MediaRequest:
      type: object
      properties:
        prompt: { type: string, maxLength: 4000 }
        model: { type: string }
        profile: { type: string, description: "Published work profile. Explicit request values override profile defaults." }
        priority: { type: integer, minimum: -10, maximum: 10, description: "Local queue priority; waiting jobs age to prevent starvation" }
        schedule: { enum: [anytime, night], description: "Night hours follow the Mac's queue settings" }
        n: { const: 1 }
        size: { type: string, pattern: "^\\d+x\\d+$|^auto$" }
        response_format: { enum: [b64_json, url] }
        negative_prompt: { type: string }
        seed: { type: integer, minimum: 0, maximum: 4294967295 }
        steps: { type: integer, minimum: 1, maximum: 150 }
        strength: { type: number, minimum: 0, maximum: 1 }
        seconds: { oneOf: [{ type: number }, { type: string }], description: "Audio length, or video length (frames = seconds × fps)" }
        frames: { type: integer }
        fps: { type: number }
        image_file_id: { type: string }
        mask_file_id: { type: string }
        audio_file_id: { type: string }
        video_file_id: { type: string }
    MediaUpload:
      allOf:
        - $ref: "#/components/schemas/MediaRequest"
        - type: object
          properties:
            image: { type: string, format: binary }
            mask: { type: string, format: binary }
            audio: { type: string, format: binary }
            input_reference: { type: string, format: binary }
    File:
      type: object
      properties:
        id: { type: string }
        object: { const: file }
        bytes: { type: integer }
        created_at: { type: integer }
        filename: { type: string }
        purpose: { type: string }
        mime_type: { type: string }
        source: { enum: [upload, job] }
        job_id: { type: string }
    Deleted:
      type: object
      properties: { id: { type: string }, object: { type: string }, deleted: { const: true } }
    Job:
      type: object
      properties:
        id: { type: string }
        object: { const: job }
        status: { enum: [queued, in_progress, completed, failed, cancelled] }
        capability: { type: string }
        model: { type: string }
        progress: { type: number, minimum: 0, maximum: 1 }
        error: { type: string }
        output_file_ids: { type: array, items: { type: string } }
        created_at: { type: integer }
        started_at: { type: integer }
        finished_at: { type: integer }
        queue_position: { type: integer, description: "Prompts ahead in ComfyUI while queued" }
        current_node: { type: string, examples: ["KSampler 12/30"] }
        eta_seconds: { type: integer }
        waiting_reason: { type: string, examples: ["Waiting for memory: 2.1 of 4.0 GB free"] }
        priority: { type: integer }
        schedule: { enum: [anytime, night] }
        has_preview: { type: boolean }
        has_recipe: { type: boolean }
        error_code: { type: string, description: "Set when failed", examples: [model_unsupported, insufficient_memory, provider_timeout, job_failed] }
    Recipe:
      type: object
      required: [schemaVersion, workflowName, workflowVersion, parameters, inputs, modelFiles]
      properties:
        schemaVersion: { type: integer, const: 1 }
        workflowName: { type: string }
        workflowVersion: { type: string, description: SHA-256 of the saved workflow configuration }
        parentJobID: { type: string }
        workProfileID: { type: string }
        workProfileName: { type: string }
        priority: { type: integer }
        schedule: { enum: [anytime, night] }
        modelFiles: { type: array, items: { type: string }, description: Model filenames, not binary checksums }
        inputs:
          type: array
          items:
            type: object
            required: [kind, fileID, filename, sha256]
            properties:
              kind: { enum: [image, mask, audio, video] }
              fileID: { type: string }
              filename: { type: string }
              sha256: { type: string }
        parameters:
          type: object
          required: [prompt]
          properties:
            prompt: { type: string }
            negativePrompt: { type: string }
            seed: { type: integer }
            steps: { type: integer }
            width: { type: integer }
            height: { type: integer }
            denoise: { type: number }
            seconds: { type: number }
            frames: { type: integer }
            fps: { type: number }
    WorkProfile:
      type: object
      required: [id, name, models]
      properties:
        id: { type: string }
        name: { type: string }
        models: { type: object, additionalProperties: { type: string } }
        steps: { type: integer }
        width: { type: integer }
        height: { type: integer }
        negativePrompt: { type: string }
        priority: { type: integer }
        schedule: { enum: [anytime, night] }
        seconds: { type: number }
        fps: { type: number }
    Video:
      type: object
      properties:
        id: { type: string }
        object: { const: video }
        status: { enum: [queued, in_progress, completed, failed] }
        progress: { type: integer, minimum: 0, maximum: 100 }
        created_at: { type: integer }
        completed_at: { type: integer }
        model: { type: string }
        file_id: { type: string }
        error: { type: object, properties: { code: { type: string }, message: { type: string } } }

"""#
