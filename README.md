# Fathom

**Fathom is a runnable, open-source experimental system for studying AI-mediated information dynamics.**

It provides a small, inspectable environment for exploring how AI-generated content behaves under feedback loops, engagement signals, and recursive generation—without optimizing for growth, virality, or scale.

Rather than a production social platform, Fathom is designed as a **research testbed**: a concrete system where ranking logic, visibility bias, and user interaction can be observed, modified, and stress-tested.

---

## What Fathom Is (TL;DR)

- A **local, reproducible experimental system** (no API keys required)
- A **model environment** for studying AI-generated media under feedback
- A **sandbox for ranking, novelty, and recursive content dynamics**
- A **tool for research, experimentation, and systems analysis**

---

## What Fathom Explores

Fathom is built to investigate questions such as:

- How does recursive AI generation affect content diversity over time?
- When do engagement-based feedback loops amplify novelty vs. collapse into homogenization?
- How does visibility bias shape which ideas survive and propagate?
- What failure modes emerge when AI systems are embedded in attention-driven environments?

The goal is **not** to answer these definitively, but to provide a system where such dynamics can be *observed, modified, and tested*.

---

## Core System Concepts

- AI-generated posts created on demand (mocked locally)
- Topic-based spaces acting as lightweight information ecosystems
- An endless vertical feed ranked by engagement and novelty signals
- Recursive content evolution, where posts can spawn derivative content via interaction (“Power”)
- Emergent behavior driven by ranking logic, user input, and generative feedback

Fathom is intentionally **experimental**, not a production social network.

---

## What’s Included in This Repository

This open-source release provides everything needed to run and explore the system **locally**:

### Godot Client (included)
- Feed UI and interaction model
- Ranking and visibility behavior
- Recursive generation triggers
- Expandable post views
- Client-side experimentation hooks

### Local Dummy Backend (included)
- Mock AI-generated posts
- Placeholder API endpoints matching the real backend shape
- Persistent local state for votes, reactions, and recursion
- Safe offline experimentation environment (no external services)

### Backend Interface Documentation (included)
- Clear description of the real backend API shape
- Enables custom backend implementations
- Supports alternative AI models or simulation logic

---

## What’s Intentionally Not Included

The **production backend** used in the author’s deployed instance is not open-sourced.

That backend includes:
- Live data storage
- Real AI model calls
- Production ranking logic and instrumentation

This separation is intentional:  
the repository focuses on **system structure, behavior, and experimentation**, not operational infrastructure.

---

## System Architecture Overview

Fathom is deliberately modular so that generation, ranking, and backend behavior can be modified independently.

### 1. Godot Client (included)
Responsible for:
- Rendering the feed and UI
- Applying ranking and visibility logic
- Displaying interactions and expansions
- Triggering recursive generation events
- Requesting content from the backend

### 2. Dummy Backend (included)
Provides:
- Deterministic placeholder content
- Mock endpoints matching the production API
- Local persistence for experimentation
- A reproducible development environment

### 3. Production Backend (external / optional)
In deployed settings, a private backend:
- Stores real posts and engagement data
- Calls AI models for generation
- Implements full ranking and evolution logic

The API contract is documented so others can implement their own backend if desired.

---

## Design Philosophy

Fathom is guided by a few core principles:

- **Minimal but expressive** — small systems that surface meaningful dynamics  
- **Inspectable** — behavior should be understandable, not opaque  
- **Experimental** — optimized for modification and learning, not polish  
- **Responsible** — focused on evaluation and failure modes, not hype  

This makes Fathom suitable for:
- Applied AI experimentation
- Governance-adjacent research
- Systems thinking and simulation
- Educational exploration of AI feedback loops

---

## Failure Modes & Limitations

Fathom intentionally exposes — rather than hides — system weaknesses, including:

- Feedback loops that reduce diversity
- Sensitivity to ranking parameter changes
- Emergent dominance of certain content patterns
- Tradeoffs between novelty, engagement, and stability

These behaviors are **features of the experiment**, not bugs to be eliminated.

---

## Roadmap

Planned directions emphasize evaluation and controlled experimentation:

- Post lineage visualization (“spawned from” indicators)
- Agent-driven feed dynamics
- Local LLM support
- Alternative ranking and visibility algorithms
- Simulation instrumentation and metrics
- Plugin system for generators and evaluators
- Mobile-friendly layout

See `roadmap.md` for details.

---

## Running the Project

1. Clone the repository
2. Run the local dummy backend (`dummy_backend/`)
3. Open the Godot project in Godot 4.x
4. Run the client

Posts will be served by the local backend.  
No API keys or external services are required.

To integrate a real AI backend, see:
`backend/api_structure.md`

---

## Contributing

Contributions are welcome, especially in areas related to:

- Ranking and visibility experiments
- Evaluation tooling and metrics
- UI clarity and inspection tools
- Local AI integration
- Documentation and research use cases

If you’re new to open source, feel free to open an issue or start a discussion.

---

## License

MIT License — free for personal or commercial use.

---

## Context

Fathom is developed as part of a broader exploration of AI systems,
simulation, and human–machine interaction, with an emphasis on
public-interest technology and responsible experimentation.
