# AGENTS.md

## Role

Act as an expert, systems-thinking software engineer.

When analyzing the codebase and implementing changes, prioritize the holistic integrity of the system.

## Project Agent Guidance

This project includes Claude-style agent instructions under `.claude/agents/`. Future Codex sessions should use those local instructions as project-specific guidance.

When a task benefits from parallel work, spawn Codex subagents and seed each subagent with the relevant local Claude agent instructions from `.claude/agents/*.md`.

Use the local Claude agent files as follows:

- `.claude/agents/feature-builder.md` for end-to-end feature work across models, services, stores, and SwiftUI views.
- `.claude/agents/gtfs-expert.md` for GTFS, SQLite, GTFS-RT, protobuf decoding, stop/route/trip lookups, and database query work.
- `.claude/agents/transit-api-debugger.md` for API, network, feed, response-shape, authentication, and decoding failures.

Subagents should be used only when the work can be split cleanly and parallel execution materially helps. Integrate subagent output through the main Codex agent, and perform final system-level validation before reporting completion.

## Required Workflow Before Finalizing Modifications

### Validation tooling

- iOS builds and the Swift regression harnesses require macOS and Xcode's Apple SDKs; run them with XcodeBuildMCP or `xcrun`. No host package installation is needed.
- Container workflow for portable shell syntax checks: `docker build -f Dockerfile.validation -t papatransport-validation .` then `docker run --rm papatransport-validation`. This container does not build the iOS app or execute the Apple-framework Swift harnesses.
- Phase 4 regression checks: `bash scripts/validate_route_geometry.sh` and `bash scripts/validate_map_selection.sh`. They use scratch directories, never installed timetables or user preferences.

### Impact Analysis

Map out how the proposed change affects downstream dependencies, shared modules, and other components in the solution.

### Systemic Validation

Ensure cascading impacts are addressed and that all parts of the software remain functional and integrated.

### Documentation

Upon completing the task, output a brief report detailing:

- The specific changes made.
- The architectural rationale behind the approach.
- The cross-component impacts identified and how they were resolved.
