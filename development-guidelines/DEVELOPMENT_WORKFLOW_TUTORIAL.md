# Working with Claude Code: A Practical Tutorial

Learn how to use Claude Code to develop Swift library features using the Design-First TDD workflow.

## Overview

This tutorial shows you the actual prompts, commands, and workflow for collaborating with Claude Code on Swift development. You'll learn:

- How to create a new project from scratch
- How to set up the development guidelines in your project
- How to start a new feature development session
- What to say to move through each phase
- How to hand off work between sessions
- How to resume and continue interrupted work
- Tips for effective human-LLM collaboration

## Prerequisites

Before starting, ensure you have:

- Swift 6.0+ installed (`swift --version` to check)
- Claude Code installed (`npm install -g @anthropic-ai/claude-code`)
- Git installed and configured
- A GitHub account (optional, for remote repos)

---

## Part 1: Creating a New Project

This section walks through creating a brand new Swift library project with the development guidelines.

### Step 1: Create the Project Folder

Choose where you want your project to live and create it:

```bash
# Create and enter your project directory
mkdir -p ~/Projects/MyMathLibrary
cd ~/Projects/MyMathLibrary
```

### Step 2: Clone the Development Guidelines

Clone the guidelines repo into your project. The guidelines will live alongside your source code:

```bash
# Clone the development guidelines
git clone https://github.com/jpurnell/development-guidelines.git .guidelines

# Or if you want them in the project root (recommended for visibility):
git clone https://github.com/jpurnell/development-guidelines.git temp-guidelines
mv temp-guidelines/00_CORE_RULES .
mv temp-guidelines/05_SUMMARIES .
rm -rf temp-guidelines
```

Your structure now looks like:

```
MyMathLibrary/
├── 00_CORE_RULES/
│   ├── 00_MASTER_PLAN.md
│   ├── 01_CODING_RULES.md
│   ├── 03_DOCC_GUIDELINES.md
│   └── ...
└── 05_SUMMARIES/
    └── SESSION_SUMMARY_TEMPLATE.md
```

### Step 3: Initialize the Swift Package

Now create the Swift package structure:

```bash
# Initialize a new Swift package library
swift package init --type library --name MyMathLibrary
```

This creates:

```
MyMathLibrary/
├── 00_CORE_RULES/
├── 05_SUMMARIES/
├── Sources/
│   └── MyMathLibrary/
│       └── MyMathLibrary.swift
├── Tests/
│   └── MyMathLibraryTests/
│       └── MyMathLibraryTests.swift
└── Package.swift
```

### Step 4: Configure Package.swift

Open `Package.swift` and configure it for Swift 6 with strict concurrency:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyMathLibrary",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MyMathLibrary",
            targets: ["MyMathLibrary"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyMathLibrary",
            dependencies: [
                .product(name: "Numerics", package: "swift-numerics"),
            ],
            swiftSettings: [
                .strictConcurrency(.complete)
            ]
        ),
        .testTarget(
            name: "MyMathLibraryTests",
            dependencies: ["MyMathLibrary"]
        ),
    ]
)
```

### Step 5: Open in Xcode (Optional)

If you prefer developing in Xcode rather than purely on the command line, you can open the package directly:

```bash
# Open the package in Xcode
open Package.swift
```

Xcode natively supports Swift packages - just open `Package.swift` and Xcode will:
- Resolve and fetch dependencies automatically
- Create a scheme for building and testing
- Enable full IDE features (autocomplete, debugging, etc.)

**Tips for Xcode + Claude Code workflow:**

- Keep Xcode open for editing, debugging, and running tests visually
- Use Claude Code in a terminal for guided development and phase management
- Xcode and the terminal share the same source files - changes sync automatically
- Run `swift build` in terminal to verify command-line builds still work

**Adding a Documentation Catalog (for DocC):**

To enable DocC documentation previews in Xcode:

1. In Xcode, right-click your target's folder in the navigator
2. Select **New File** → **Documentation Catalog**
3. Name it `MyMathLibrary.docc`
4. Add your documentation articles here

Or create it manually:

```bash
mkdir -p Sources/MyMathLibrary/MyMathLibrary.docc
cat << 'EOF' > Sources/MyMathLibrary/MyMathLibrary.docc/MyMathLibrary.md
# ``MyMathLibrary``

A Swift library for mathematical operations.

## Overview

MyMathLibrary provides statistical and mathematical functions
with a focus on safety and numerical stability.

## Topics

### Statistics

- ``mean(_:)``
EOF
```

### Step 6: Initialize Git

Set up version control:

```bash
# Initialize git repo
git init

# Create .gitignore
cat << 'EOF' > .gitignore
.DS_Store
.build/
.swiftpm/
*.xcodeproj
xcuserdata/
DerivedData/
.claude/
EOF

# Initial commit
git add .
git commit -m "Initial project setup with development guidelines"
```

### Step 7: Install Quality Gate

Install the `quality-gate` CLI tool to automate all quality checks:

```bash
# Clone and build
git clone https://github.com/jpurnell/quality-gate-swift.git /tmp/quality-gate-swift
cd /tmp/quality-gate-swift
swift build -c release
sudo cp .build/release/quality-gate /usr/local/bin/
cd -

# Verify installation
quality-gate --help
```

Alternatively, add it as an SPM plugin to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/quality-gate-swift.git", from: "1.0.0"),
]
```

Then run via: `swift package plugin quality-gate`

### Step 8: Verify the Setup

Run the quality gate to ensure everything works:

```bash
quality-gate
```

You should see all checks pass:

```
==========================================
  Quality Gate Results
==========================================

✓ [build] PASSED
✓ [test] PASSED
✓ [safety] PASSED

==========================================
✅ Quality Gate: PASSED
==========================================
```

---

## Part 2: Your First Claude Code Session

Now that your project is set up, let's start Claude Code and begin development.

### Step 1: Launch Claude Code

From your project root:

```bash
cd ~/Projects/MyMathLibrary
claude
```

Claude Code will scan your project and see:
- The Swift package structure
- The development guidelines in `00_CORE_RULES/`
- Any existing source files

### Step 2: Orient Claude Code to Your Project

Start with an orientation prompt so Claude Code understands the context:

```
This is a new Swift math library project. I've included development guidelines
in the 00_CORE_RULES/ folder that define our workflow:

- Phase 0: Design Proposal (before any code)
- Phase 1: Testing (write failing tests first)
- Phase 2: Implementation (minimum code to pass tests)
- Phase 3: Refactoring (clean up, safety audit)
- Phase 4: Documentation (complete DocC comments)
- Phase 5: Quality Gates (zero warnings, all tests pass)

Please read the guidelines files to understand the process. Let me know
when you're ready to start on our first feature.
```

Claude Code will read your guidelines and confirm understanding.

### Step 3: Start Your First Feature

Now introduce the feature you want to build:

```
I want to implement our first function: `mean()` to calculate the arithmetic
mean of an array of numbers. It should be generic over Real types.

Let's start with Phase 0 - create a design proposal.
```

Claude Code will create a design proposal document in `02_IMPLEMENTATION_PLANS/PROPOSALS/` for your review.

---

## Part 3: Moving Through the Development Phases

Once you have a project set up and Claude Code oriented, here's how to move through each phase.

### Phase 0: Design Proposal

Claude Code will create a design proposal document in `02_IMPLEMENTATION_PLANS/PROPOSALS/` for your review. Review it carefully:

**Example response from Claude:**

> I've drafted a design proposal for the variance function. Key decisions:
> - Location: `Sources/Statistics/Variance.swift`
> - API: `func variance<T: Real>(_ values: [T], ddof: Int = 0) throws -> T`
> - The `ddof` parameter controls degrees of freedom (0 for population, 1 for sample)
>
> Does this approach work, or would you like changes?

**Your response options:**

```
# If approved:
Looks good. Let's move to Phase 1 - writing the tests.

# If changes needed:
I'd prefer a simpler API without the ddof parameter. Just population variance
for now. We can add sample variance as a separate function later.
```

### Phase 0 → Phase 1 (Design → Testing)

Once design is approved, explicitly transition:

```
Design approved. Let's move to Phase 1 - write the failing tests first.
Follow the testing guidelines: golden path, edge cases, invalid inputs,
and property-based tests.
```

Claude Code will create the test file with comprehensive test cases.

### Phase 1 → Phase 2 (Testing → Implementation)

After reviewing tests:

```
Tests look complete. Move to Phase 2 - implement the minimum code to
make these tests pass. Remember: no force unwraps, guard clauses for
validation, division safety checks.
```

### Phase 2 → Phase 3 (Implementation → Refactoring)

Once tests pass:

```
All tests passing. Move to Phase 3 - refactor for clarity and run the
safety audit. Search for any force operations or unsafe patterns.
```

### Phase 3 → Phase 4 (Refactoring → Documentation)

After refactoring:

```
Code looks clean. Move to Phase 4 - add complete DocC documentation
including usage examples, MCP schema, and complexity notes.
```

### Phase 4 → Phase 5 (Documentation → Quality Gates)

After documentation:

```
Documentation complete. Run quality-gate to verify all checks pass.
```

Claude Code will run:

```bash
quality-gate
```

This checks build, tests, safety audit, and documentation in one command.

---

## Part 4: Multi-Session Development

Real features often span multiple sessions - you might work for an hour, close the terminal, and come back the next day or even weeks later. Here's how to handle context handoff.

### Ending a Session

When you need to stop, ask Claude Code to summarize:

```
I need to stop for today. Please create a session summary documenting:
- Current phase and status
- What's completed
- What's remaining
- Exactly where to pick up next session
```

Claude Code will create or update a session summary file and the active implementation checklist at `04_IMPLEMENTATION_CHECKLISTS/CURRENT_*.md`.

### Starting a New Session (Resuming Work)

When you return, provide context:

```
I'm resuming work on the variance() function. Check the session summary
in 05_SUMMARIES/ and the implementation checklist in
04_IMPLEMENTATION_CHECKLISTS/CURRENT_*.md for where we left off.
What's the current status and what's next?
```

Or if you remember the state:

```
Resuming variance() implementation. We finished Phase 2 (tests passing).
Let's continue with Phase 3 - refactoring and safety audit.
```

### Mid-Phase Resume

If you stopped in the middle of a phase:

```
Resuming variance() work. We were in Phase 1 writing tests. I think we
had golden path tests done but still needed edge cases. Can you check
the test file and continue from there?
```

### Cold Start (After a Long Break)

If you're returning after days or weeks and don't remember the state:

```
I'm returning to this project after a break. Please:
1. Check 05_SUMMARIES/ for any session summaries
2. Check 04_IMPLEMENTATION_CHECKLISTS/CURRENT_*.md for active checklists
3. Look at recent git commits to see what was done
4. Check for any TODO comments or incomplete features
5. Give me a status report and recommend what to work on next
```

Claude Code will investigate and report back with the project state.

### Starting a New Feature (In an Existing Project)

When you want to add a new feature to a project you've already set up:

```
I want to add a new feature: [description]. This project already has
the development guidelines set up. Let's start with Phase 0 - design proposal.
```

---

## Part 5: Quick Reference

### Common Prompts

#### Starting Work

| Situation | Prompt |
|-----------|--------|
| New feature | "I want to implement [feature]. Follow the dev guidelines. Start with Phase 0 design proposal." |
| Bug fix | "There's a bug in [function]: [description]. Diagnose the issue and propose a fix." |
| Resume work | "Resuming [feature]. Check session summary for status. What's next?" |

#### Phase Transitions

| Transition | Prompt |
|------------|--------|
| Design → Tests | "Design approved. Move to Phase 1 - write failing tests." |
| Tests → Implementation | "Tests complete. Move to Phase 2 - minimum implementation to pass." |
| Implementation → Refactor | "Tests passing. Move to Phase 3 - refactor and safety audit." |
| Refactor → Docs | "Code clean. Move to Phase 4 - complete DocC documentation." |
| Docs → Gates | "Docs done. Run quality-gate." |

#### Quality Control

| Check | Prompt |
|-------|--------|
| Run tests | "Run the test suite and report results." |
| Safety audit | "Run `quality-gate --check safety` to find forbidden patterns." |
| Full quality gate | "Run `quality-gate` to verify all checks pass." |
| Specific checks | "Run `quality-gate --check build --check test`" |

#### Session Management

| Action | Prompt |
|--------|--------|
| End session | "Create a session summary documenting current status and next steps." |
| Check status | "What's the current status of [feature]? Which phase are we in?" |
| Review progress | "Show me what we've completed today on [feature]." |

---

## Part 6: Tips for Effective Collaboration

### Be Explicit About Phases

Claude Code works best when you clearly state which phase you're in:

```
# Good - explicit phase
"We're in Phase 1. Write edge case tests for empty arrays and single elements."

# Less effective - ambiguous
"Add some more tests."
```

### Reference the Guidelines

When Claude Code's output doesn't match your standards, reference specific rules:

```
"The documentation is missing the MCP schema section. Check 03_DOCC_GUIDELINES.md -
all public APIs need MCP schemas."
```

### Ask for Verification

After each phase, ask Claude Code to verify compliance:

```
"Before we move on, verify this implementation follows 01_CODING_RULES.md -
especially the safety rules about division and bounds checking."
```

### Provide Feedback

If something isn't right, be specific:

```
# Good - specific feedback
"The test for empty arrays should throw StatisticsError.emptyInput,
not return nil. Fix that test case."

# Less helpful - vague
"The tests aren't quite right."
```

### Use Checkpoints

For complex features, create explicit checkpoints:

```
"We've completed Phase 2. Before Phase 3, let's checkpoint:
- Confirm all 15 tests pass
- List any TODO comments in the code
- Note any design decisions we made"
```

---

## Part 7: Example Complete Session

Here's a realistic session flow for adding a `median()` function:

**You:**
```
I want to add a median() function to calculate the median of an array.
Follow the development guidelines. Start with Phase 0.
```

**Claude Code:** *Creates design proposal, asks about handling even-length arrays*

**You:**
```
For even-length arrays, return the average of the two middle values.
Design looks good - move to Phase 1, write the tests.
```

**Claude Code:** *Creates test file with golden path, edge cases, invalid input tests*

**You:**
```
Add one more test: verify median of [1,2,3,4] returns 2.5 (average of 2 and 3).
Then move to Phase 2.
```

**Claude Code:** *Adds test, implements function*

**You:**
```
Tests pass. Move to Phase 3 - refactor and run safety audit.
```

**Claude Code:** *Reviews code, reports no safety issues*

**You:**
```
Good. Move to Phase 4 - full DocC documentation with examples and MCP schema.
```

**Claude Code:** *Adds documentation*

**You:**
```
Run Phase 5 quality gates.
```

**Claude Code:** *Runs all checks, reports success*

**You:**
```
Perfect. Create a session summary and we're done with this feature.
```

---

## Part 8: Troubleshooting

### Claude Code Skips Phases

If Claude Code tries to jump ahead:

```
"Stop - we're still in Phase 1. Don't write implementation code yet.
Finish the property-based tests first."
```

### Tests Written After Code

If tests appear after implementation:

```
"We need to follow TDD. Delete the implementation, keep only the tests.
Let's verify tests fail, then implement."
```

### Missing Documentation Sections

If docs are incomplete:

```
"The documentation is missing required sections. Check 03_DOCC_GUIDELINES.md
and add: Complexity, MCP Schema, and a playground-ready example."
```

### Quality Gate Failures

If a gate fails:

```
"The strict concurrency check failed. Show me the errors and fix them
before we proceed."
```

---

## Part 9: Ongoing Maintenance

As your project grows over months or years, documentation files can bloat and overwhelm Claude's context window. Run periodic maintenance to keep things manageable.

### Quarterly Maintenance Prompt

```
Please perform quarterly file hygiene:

1. Session Summaries: Move files older than 3 months to 05_99_ARCHIVE/[YEAR]/
2. Implementation Checklists: Verify all shipped features in `04_IMPLEMENTATION_CHECKLISTS/CURRENT_*.md` moved to `04_IMPLEMENTATION_CHECKLISTS/04_99_COMPLETED/`
3. Design Proposals: Move SHIPPED/REJECTED proposals to archive
4. Phase Summary: If we've completed 10+ sessions, create a new phase summary
5. Blocked Items: Review `04_IMPLEMENTATION_CHECKLISTS/04_99_BLOCKED/` - any blockers resolved?

Report what was archived and confirm active files are under size limits.
```

### File Size Limits

| File | Max Lines | When Exceeded |
|------|-----------|---------------|
| Session summaries | ~150 | One per session |
| Implementation checklists (`04_IMPLEMENTATION_CHECKLISTS/CURRENT_*.md`) | ~100 | One per feature, archive to `04_99_COMPLETED/` when shipped |
| Master plan | ~300 | Move decisions to log |
| Design proposals | ~150 each | Archive when shipped |

### Architecture Decisions Log

Major decisions should go in a structured, machine-readable log (`06_ARCHITECTURE_DECISIONS.md`) using YAML blocks. This can grow indefinitely because Claude can query specific entries without reading the whole file.

See [07_SESSION_WORKFLOW.md](00_CORE_RULES/07_SESSION_WORKFLOW.md) Part 7 for full details on file hygiene.

---

## Next Steps

- Keep these guidelines in your project root so Claude Code can reference them
- Start with a small feature to practice the workflow
- Iterate on your prompts based on what works best for your style
- Run quarterly maintenance to prevent file bloat

## See Also

- [00_MASTER_PLAN.md](00_CORE_RULES/00_MASTER_PLAN.md) - Project architecture
- [07_SESSION_WORKFLOW.md](00_CORE_RULES/07_SESSION_WORKFLOW.md) - Session handover details
- [04_IMPLEMENTATION_CHECKLISTS/TEMPLATE.md](04_IMPLEMENTATION_CHECKLISTS/TEMPLATE.md) - Implementation checklist template
- [05_SUMMARIES/SESSION_SUMMARY_TEMPLATE.md](05_SUMMARIES/SESSION_SUMMARY_TEMPLATE.md) - Summary format
