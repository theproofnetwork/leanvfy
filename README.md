# leanvfy
Workflow to attest successful lean verification of a given statement with unfalsifiable provenance and integrity guarantees

When an possibly dishonest actor claims to have proven a mathematical statement,
they can supply a formal lean formalization of the statement and a formal proof of it.
However, this proof needs to be verified by a trusted lean kernel, which may entail large runtime costs.
Thus it is desirable to have the untrusted prover provide a certificate (attestation) of the verification
running on their resources.
Cryptographic techniques like secure multiparty computation or SNARKs (Succinct Non-interactive ARgument of Knowledge)
exhibit nice properties for this purpose, but there computational overhead make them impractical for most applications
including lean proofs.
Thus this repo introduces a secure computing environment on top of github actions that provers can run from their
repositories and accounts and thus pay for the computational costs themselves, while still being able
to provide an attestation of workflow integrity and provenance. That is a certificate that this exact
workflow has been run with the attested inputs and outputs.
Verifying these attestations is very cheap and allows other parties to trust
the correctness of the proof without having to run the expensive verification themselves.

On top of ensuring that a trusted lean environment was used for verification,
one has to deal with adversarial theorem descriptions (challenges) and proof packages (solutions).
Not only can they try to exploit unpatched bugs in a lean kernel, add axioms or redefine objects referenced in the statement,
but Lean packages allow arbitrary code execution inside the workflow.

Challenge and solution are each a git repository at a commit holding a Lake package, with whatever
dependencies (Mathlib, the challenge itself, anything) their `lake-manifest.json` pins.
This workflow builds and exports (with lean4export) the challenge workspace in a sealed sandbox
holding nothing else, then does the same for the solution workspace in a second one, and finally runs
lean comparator in a third sandbox that contains only the two exports and the verifier binaries.
Comparator ensures that the challenge and solution state the theorem identically and don't employ any
dishonest tricks, and checks the one solution export for correctness not only using the official lean kernel,
but also using nanoda and eink0rn, two independently implemented kernels that consume the
[lean4export](https://github.com/leanprover/lean4export) format and are tracked on the
[Lean Kernel Arena](https://arena.lean-lang.org/).
This helps guarding against exploits that are only present in one of the kernels.
Every kernel judges the same exported bytes, and each external kernel runs in its own landrun sandbox.
Prover code runs only in the two build sandboxes, which are gone before the verdict is computed.

<!-- TODO upstream on lean/comparator: request the option to provide exports directly -->

## Adversarial model

We model three parties which may coincide: <br>
The challenger, who formalizes a problem in a challenge Lean package (a git repository).<br>
The prover, who claims to have proven a specified challenge and provides a lean proof.<br>
The verifier, who wants to know whether the prover's claim is true in respect to a given challenge.<br>

The adverserial model takes the perspective of the verifier and assumes that the
prover may be dishonest and adverse.
We assume the challenger to be honest, that is the verifier trusts the challenge package at a given commit
-- e.g. by checking its source code and verifying that it formalizes the intended problem.

The prover runs this workflow and wants to convince the verifier by providing
an attestation of a passing verification.
They control the repository the workflow is executed in, the inputs to the workflow
**including** the challenge and solution repositories provided to the workflow, and every
dependency those repositories pull in.
That means that while the claimed challenge is assumed to be honest,
the prover may run the workflow with an adversarial challenge to trick the verifier into producing an attestation for the claimed challenge.
They may run on a self-hosted runner, which we have to defend against, since
we cannot trust self-hosted runners.
What we do trust is github itself.
Specifically that github-hosted runners are fresh, unmodified machines,
and that the OIDC identity and the sigstore signature produced by `actions/attest`
can only be obtained by the workflow they claim to come from.
We trust our pinned toolchain dependencies and the tools used in the workflow.

In the lean kernels we only put a 1-out-of-n trust. Thus we only assume
that not all of the (currently) three kernels (lean, nanoda, eink0rn) can be exploited at a time.
They were chosen for different lineages: nanoda is an independent Rust implementation of the C++ kernel's
algorithm, eink0rn a clean-room Haskell kernel with a different checking strategy. Kernels that share code
with the C++ kernel (such as lean4lean, which uses Lean's own `Expr` primitives) add less to this assumption.

Since the prover pays for the runtime, we don not care about DoS type attacks like consuming lots of CPU time or memory or disk space.

This leaves the prover still with lots of attack vectors:
- arbitrary code execution when compiling the lean files, in `lakefile.lean`s and in dependency build scripts,
- adding axioms or hiding sorrys,
- shadowing or redefining names the challenge relies on,
- pointing the workflow at hostile git repositories, URLs and Lake manifests,
- shipping prebuilt `.olean`s so that what is checked is not what is in the sources,
- exploit soundness bugs in a specific lean kernel
- and possibly many more.

## Mitigations and Security Considerations

### Repositories, dependencies and the two workspaces

Both inputs are git repositories at a full commit id. The workflow checks each out with
[scripts/fetch-repo.sh](scripts/fetch-repo.sh), the only code path through which prover-controlled
bytes reach the runner: https only (also across redirects, `protocol.allow=never`), no credentials
and no host git configuration, git itself confined to a bubblewrap jail that can write nothing but the
destination directory, `fsckObjects` on, exactly the requested commit (verified after checkout),
no submodules. The tree must not contain a `.lake` entry at any depth nor Lake build outputs
(`*.olean`, `*.ilean`, `*.trace`, `*.hash`): a committed olean with a matching trace would make
`lake build` a no-op and the exported environment would come from bytes no reviewer of the sources
sees. `.lake` is created empty by the workflow, so every olean the run reads was produced in this run
by the attested toolchain from the committed sources. Every later git invocation on a checkout (the
tree digest below) goes through the same jail ([scripts/git-jail.sh](scripts/git-jail.sh)), read-only
and without network: reading packs and resolving deltas are git code paths of their own, and the
object store is prover-controlled bytes, so no git process ever touches them outside a jail.

Dependencies come from each repository's `lake-manifest.json`, which lists the flattened transitive
set with a git URL and an exact revision per package. [scripts/materialize-deps.sh](scripts/materialize-deps.sh)
checks every entry out through the same `fetch-repo.sh` (rejecting `path` dependencies, unpinned
revisions and manifests that relocate `.lake`) so that `lake build` inside the network-less jail finds
each package already at the pinned revision. Lake never runs on the host: `lake update` would elaborate
dependency `lakefile.lean`s. Nothing is ever downloaded from a build cache; Mathlib and everything
else compile from source inside the jail (`lake build --no-cache`), so a challenge should import only
the Mathlib modules it needs -- a full `import Mathlib` on a hosted runner will run into GitHub's job
limits. Dependencies must build with the pinned Lean release; the repository's `lean-toolchain` file
is ignored.

The challenge and the solution are separate Lake workspaces, each built and exported by
[scripts/sandboxed-build-export.sh](scripts/sandboxed-build-export.sh) in its own throwaway bubblewrap
jail: the jail holds that one workspace (read-only except its `.lake`) and the toolchain, has no
network, and the only thing that leaves it is the lean4export text through a pipe owned by the host
script. The challenge is built first; a build jail never sees the other workspace or export, and every
process a build started is gone when its jail exits. The two exports then go to comparator in a third
jail ([scripts/sandboxed-comparator.sh](scripts/sandboxed-comparator.sh)) that contains only the verifier
binaries and the exports -- no Lean, no Lake, no workspace, so no prover code exists any more when the
statement comparison, the axiom check and the kernels produce the verdict, only prover bytes to parse.
Comparator's mode for this is [patches/comparator/supply-exports.patch](patches/comparator/supply-exports.patch):
given two exports it skips building and exporting, and `comparator --print-export-targets` tells the
build jails which declarations (the theorem, the permitted axioms, the kernel's built-in constants) the
exports must cover; an export missing any of them, or any constant in the statement's closure, is
rejected. The solution
may `require` the challenge repository and `import` the modules holding the definitions the statement
uses (not the module declaring the theorem itself, whose `sorry` declaration would occupy the name), or
restate the definitions -- comparator compares the exported kernel terms of the statement's whole
closure by name, so what matters is that the terms match, not where the solution's copy came from.
The theorem itself is always re-declared, with its proof, in the solution's module. The prover's copy of the challenge inside the
solution workspace is untrusted and irrelevant: the comparison is against the export of the trusted
checkout. Solution dependencies are as untrusted as the solution; only the closure of the theorem is
exported and it is replayed through all three kernels, so whatever they contain is judged by the same
rules. The pinned `lean4export` imports modules without loading extensions or running initializers, so
no `initialize` block of an untrusted module runs inside the exporter.

Both builds execute prover-supplied code (the challenge, too, is whatever the prover passed in). Trust
in the challenge is about what its sources *mean* to a reviewer, not about its build being benign,
which is why the challenge root must be configured by `lakefile.toml`: unlike a `lakefile.lean` it
cannot run code at `lake build` time and write oleans the sources do not account for. A hostile
challenge otherwise gains nothing: whatever it does is attested as *that* challenge, by commit id,
tree digest and module, and a verifier comparing those against the claimed challenge rejects it.

#### What a verifier must audit in a challenge

The attestation says that `theorem`, as declared in `challenge.annotations.module` of the commit
`challenge.digest.gitCommit`, was proven. To know what was proven, audit at that commit: the named
module and everything it imports from the repository, `lakefile.toml`, and the dependency revisions
pinned in `lake-manifest.json` (the statement's meaning depends on the definitions it pulls from
them). Check all three of commit, module and theorem name against the predicate; the same theorem
name can legitimately exist in several modules of one repository. [verify.sh](verify.sh) performs
these comparisons, together with the certificate checks below, given the audited commit.

### Attestation contents

The workflow signs an [in-toto Statement](https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md)
via `actions/attest`. What a verifier learns is split over two layers:

| Fact | Attestation | Why there |
|---|---|---|
| workflow@commit (`job_workflow_ref`, `job_workflow_sha`) | Sigstore certificate (Fulcio extensions, `1.3.6.1.4.1.57264.1.9` / `.10`) | Comes from GitHub's OIDC token; cannot be forged by the prover |
| GitHub-hosted vs. self-hosted runner (`runner_environment`) | Certificate (`1.3.6.1.4.1.57264.1.11`) | Same |
| Prover's repository, ref, run URL, trigger | Certificate (`.12`-`.21`) | Same |
| Time of signing | Certificate validity / Rekor `integratedTime` | Same |
| Challenge and solution tree digests | Statement `subject` **and** predicate `challenge.digest.sha256` / `solution.digest.sha256` | `subject` lets `gh attestation verify` find the attestation; the predicate copies bind each digest to its *role* (trusted challenge vs. untrusted solution) |
| Challenge and solution commit ids, repository URLs and modules | Predicate `challenge` / `solution` (`digest.gitCommit`, `uri`, `annotations.module`) | The commit id is what a verifier compares against the challenge they audited; the URL is only a locator |
| Theorem name, result, axiom policy, pinned toolchain (incl. tool patches) | Predicate ([schemas/leanvfy-v1.json](schemas/leanvfy-v1.json)) | Computed by the trusted workflow code; not expressible in the certificate |

The tree digest ([scripts/tree-digest.sh](scripts/tree-digest.sh)) is the sha256 over the
NUL-terminated records `<mode> <sha256 of blob content> <path>` for every blob of
`git ls-tree -r <commit>`, in git's order. Git commit ids are SHA-1 in almost every repository and
`actions/attest` indexes subjects by sha256; the digest binds every path, mode and byte of the
checked-out tree independently of SHA-1 and is reproducible on any clone of the commit. Records are
NUL- rather than newline-terminated because NUL is the one byte a git tree name cannot contain, which
is what makes the listing an unambiguous encoding of the tree.

The predicate therefore contains **no** workflow identity, runner type, repository or timestamp fields.
A verifier MUST take those from the certificate and MUST NOT accept a predicate-supplied value in their place.
The predicate's `policy` and `toolchain` blocks are fully determined by `job_workflow_sha`; they are repeated
so that consumers can read what was checked without checking out this repository, and can be cross-checked
against it via `toolchain.lock.digest.sha256`.
The only third-party code the attest job runs besides `jq` is `check-jsonschema`, installed from
[scripts/requirements.txt](scripts/requirements.txt) with `pip install --require-hashes`, so every
Python package (including transitive dependencies) is pinned by version and sha256.

Predicate type: `https://github.com/theproofnetwork/leanvfy/predicate/v1`.
Artifact references use in-toto `ResourceDescriptor`s ([schemas/in-toto-v1.json](schemas/in-toto-v1.json)),
with leanvfy-specific facts under `annotations`, in-toto's designated extension point.

### Toolchain pinning and tool releases

The workflow never installs Lean or the verifier tools from a package manager, container tag or
Actions cache. Everything comes from [toolchain.lock](toolchain.lock), which is read from the trusted
checkout at `job.workflow_sha` and therefore fixed by the attested workflow identity:

- `lean` points at an official `leanprover/lean4` release tarball and its sha256.
- `tools` lists the prebuilt binaries (`lean4export`, `comparator`, `nanoda_bin`, `eink0rn`, `landrun`)
  with their source repository, the exact commit they were built from, any patches from
  [patches/](patches/) applied on top, the build recipe, the download URL and the sha256 of the
  resulting binary.

[scripts/provision-toolchain.sh](scripts/provision-toolchain.sh) downloads each artifact over HTTPS and
rejects it unless the hash matches; the hash of the lockfile itself ends up in the predicate as
`toolchain.lock.digest.sha256`. Caching is deliberately avoided: in a reusable workflow `actions/cache`
is scoped to the *caller's* repository, i.e. the prover's, and could be seeded with tampered binaries.

#### Building and publishing the tools

The tool binaries are built by [build-tools.yml](.github/workflows/build-tools.yml)
(`workflow_dispatch`, maintainers only) via [scripts/build-tools.sh](scripts/build-tools.sh):
each tool is cloned at its pinned commit and compiled against the locked Lean release itself
(not via `elan`), so the Lean-based tools accept exactly the `.olean` files the verification
workflow produces. The Rust, Go and GHC compilers for the non-Lean tools come from the hash-pinned
official tarballs in the lockfile's `build_toolchains` block rather than from the runner image,
so a rebuild of the same lockfile uses the same compilers.
Since a crash is always the safe verdict (comparator rejects on any non-zero exit), the tools are
built so that silent misbehaviour becomes an abort where the compiler allows it: nanoda with integer
overflow checks and `panic=abort`, eink0rn with `-rtsopts=ignoreAll` so its baked-in RTS limits cannot
be overridden at run time. The usual ELF mitigations (PIE, full RELRO, non-executable stack) are
requested where the toolchain supports them and `build-tools.sh` checks the produced binaries with
`readelf` instead of trusting the flags. The Lean-based tools are compiled by the toolchain's own
`leanc` with its default flags; the C++ kernel they call is the prebuilt `libleanshared.so` of the
Lean release, whose build flags this repository cannot influence.
The binaries get an `actions/attest-build-provenance` attestation and are
attached to a GitHub release. The run's summary prints a copy of `toolchain.lock` with the real
hashes filled in; committing that copy is how a new toolchain is rolled out.

#### Release tag scheme

Tool releases are tagged `tools-<lean version>-<build number>`, e.g. `tools-v4.33.0-1`:

| Part | Meaning |
|---|---|
| `tools-` | Separates tool releases from releases of the workflow itself. |
| `v4.33.0` | The Lean release the binaries were built against. Lean-based tools embed the compiler's githash and reject `.olean`s from any other version, so a Lean bump always means a new set of binaries. |
| `-1` | Build counter within that Lean version. Bumped whenever anything else changes (a tool commit, a build fix, a toolchain used for building) without Lean changing. |

Security does not depend on the tag: `provision-toolchain.sh` enforces the sha256 next to each URL,
and the whole lockfile is hashed into the attestation. A tag that was deleted and recreated with
different assets simply fails verification.

## Usage

Call the reusable workflow from a job in the prover's repository:

```yaml
jobs:
  verify:
    uses: theproofnetwork/leanvfy/.github/workflows/leanvfy.yml@<commit>
    with:
      theorem: MyChallenge.main
      challenge_repo: https://github.com/someone/my-challenge
      challenge_commit: <full commit id>
      challenge_module: MyChallenge          # default: Challenge
      solution_repo: https://github.com/prover/my-solution
      solution_commit: <full commit id>
      solution_module: MySolution            # default: Solution
    permissions:
      id-token: write
      contents: read
      attestations: write
      artifact-metadata: write
```

(`artifact-metadata: write` is what `actions/attest` needs to record the attestation's storage
metadata; a caller granting less than the called workflow's jobs request is refused by GitHub.)

Both repositories must be public Lake packages (there are deliberately no credentials). The challenge
declares the theorem with `sorry` in `challenge_module`, is configured by `lakefile.toml` (no
`lakefile.lean` at the root), and pins its dependencies in a committed `lake-manifest.json` (required
even without dependencies: Lake would otherwise try to create one in the read-only workspace). The solution declares a
theorem of the same fully-qualified name in `solution_module`, with its proof; it may `require` the
challenge repository and `import` the modules holding the definitions the statement uses (keep the
theorem's own module separate from those, since the solution cannot import a module that already
declares the theorem), or restate the definitions. Neither tree may contain `.lake`
or Lake build outputs. Everything, dependencies included, is compiled from source with the Lean release
in [toolchain.lock](toolchain.lock) inside a network-less jail, so keep imports targeted.
### Verifying an attestation

[verify.sh](verify.sh) does the verifier's side. It needs `git`, `jq` and an authenticated
[GitHub CLI](https://cli.github.com) and runs on Linux or macOS:

```sh
git clone https://github.com/theproofnetwork/leanvfy && cd leanvfy    # review; HEAD becomes the trusted revision
./verify.sh --theorem MyChallenge.main             --challenge ~/src/my-challenge --challenge-commit <full commit id> --challenge-module MyChallenge             --prover prover/my-solution
```

`--challenge` is the verifier's own clone of the challenge they audited (or an https URL to clone);
`--prover` the repository (or owner) the prover ran the workflow in, where the attestation is fetched
from. The script:

1. lists the audited tree exactly as [scripts/tree-digest.sh](scripts/tree-digest.sh) did on the
   runner and hands that listing to `gh attestation verify`, which looks the attestation up by its
   sha256 and checks the Sigstore signature, transparency log, OIDC issuer, that the signing workflow
   is `leanvfy.yml` of this repository, that the runner was GitHub-hosted and the predicate type;
2. checks what `gh` cannot know: the certificate's `job_workflow_sha` must be a trusted revision of
   this repository (by default the commit the script runs from; more with `--workflow-commit`), the
   predicate must bind the audited digest to the *challenge* role and name the audited commit, module
   and theorem, say `PASSED`, and repeat the `toolchain` block and the axiom policy exactly as
   `toolchain.lock` and `leanvfy.yml` at that revision define them; the policy must also be within
   what the verifier accepts (`--allowed-axioms`, default `propext,Quot.sound,Classical.choice`);
3. prints the claim: the solution's repository, commit and module, the axiom policy, the prover's
   repository and run, the signing time and the toolchain (`--json` for the verified statement,
   certificate and the bundle itself).

Every accepted attestation goes through all of this; a rejection lists which claim differed. What
the script cannot do is the audit itself: that the challenge module at that commit formalizes the
intended statement is the verifier's judgement (see "What a verifier must audit in a challenge").
The solution is never needed on the verifier's machine.

#### Bundles handed over by the prover

The attestation can also travel as a file: the `bundle` of `--json`, or what `gh attestation
download` writes (one bundle per line). `--bundle FILE` verifies that instead of fetching from
GitHub. A bundle is untrusted input -- it is whatever the prover chose to hand over -- and nothing
changes about what is checked: the signature and certificate are verified by `gh` against the
Sigstore trust root, `--prover` is checked against the certificate's source repository rather than
trusted, and the claim checks above run unchanged; a bundle whose statement was altered by one byte,
or one produced in another repository, is rejected like any other. A file holding several bundles
is fine: `gh` drops the ones whose signature does not verify and the script judges the rest.

Even with a bundle, `gh` fetches the Sigstore trust root (the keys signatures are checked against)
over the network unless it is given one. For verification without network access, obtain it on a
machine and with an account you trust -- `gh attestation trusted-root > root.jsonl` -- and pass
`--trusted-root root.jsonl`. That file is then as security-relevant as the checkout of this
repository the script runs from: a stale or substituted root would accept signatures under keys
Sigstore has rotated or never issued, so refresh it as you would update the checkout.
[e2e.yml](.github/workflows/e2e.yml) exercises all of this on every push, on a genuine bundle.


## Development

Checks run through [pre-commit](https://pre-commit.com) from
[.pre-commit-config.yaml](.pre-commit-config.yaml); install them once with `pre-commit install`
and they run on every `git commit`. The `lint` job of
[test-scripts.yml](.github/workflows/test-scripts.yml) runs the identical configuration with
`pre-commit run --all-files`, so CI enforces exactly what the hook does locally. Ubuntu 24.04
and the GitHub runner image already have Python, Node and Go; pre-commit fetches the pinned tool
versions itself.

What the hooks enforce, and why:

| Concern | Hooks |
|---|---|
| Formatting | `shfmt` (4-space, indented `case`) for shell; `prettier` for YAML and the JSON schemas; LF line endings, trailing whitespace, final newlines. `toolchain.lock` is kept in exactly the `jq` layout `build-tools.sh` emits; Markdown and `patches/` are not reformatted. |
| Shell correctness | `shellcheck --severity=warning` on every script. |
| Workflows | `actionlint` (syntax, expressions, `run:` blocks), `check-github-workflows` (schema), `zizmor` security audit with [.github/zizmor.yml](.github/zizmor.yml) requiring every `uses:` -- GitHub's own actions included -- to be pinned to a full commit id. |
| Pins | [scripts/check-toolchain-lock.py](scripts/check-toolchain-lock.py): https URLs, 64-hex sha256s, tool URLs under `release_tag`, patches that exist. `requirements.txt` lines must carry `--hash=` continuations (`pip --require-hashes` in the attest job). The hook repositories themselves are pinned to commit ids with the release kept in a `# frozen:` comment; `check-frozen` verifies the two agree. |
| Secrets | `gitleaks` over the working tree; `detect-private-key`. |

Update hook versions with `pre-commit autoupdate --freeze` (keeps `rev:` a commit id);
`toolchain.lock` is updated only via `build-tools.yml`.

### Tests

The behavioural tests live in `scripts/test-*.sh`, share [scripts/test-lib.sh](scripts/test-lib.sh)
(pass/fail tally, git fixtures, and a local https git server with a throwaway CA, because every
hostile input has to arrive the way a prover's would: over https, through the jail) and print one
line per check. They run on Linux; the ones that jail need bubblewrap with `--disable-userns`
(Ubuntu 24.04) and passwordless sudo for the CA.

| Suite | What it exercises | Needs |
|---|---|---|
| [test-fetch.sh](scripts/test-fetch.sh) | `fetch-repo.sh`, `materialize-deps.sh`, `tree-digest.sh` and `verify.sh --digest-only` against hostile inputs: every non-https transport and redirect, host git configuration, committed `.lake`/oleans/submodules/`lakefile.lean`, manifest shapes, and the digest's NUL-terminated encoding (a path with a newline cannot forge records). | bwrap, sudo |
| [test-toolchain.sh](scripts/test-toolchain.sh) | `check-toolchain-lock.py` on malformed lockfiles; `provision-toolchain.sh` against a fake Lean release and tools served locally: sha256 mismatches, http and redirects, install targets, root-owned read-only results, `--lean-only`; `build-predicate.sh`: the predicate mirrors the lockfile and the schema rejects malformed claims. | sudo, check-jsonschema |
| [test-verify.sh](scripts/test-verify.sh) | `verify.sh` with a shim `gh` on PATH that records how `gh attestation verify` is invoked (subject listing, issuer, signer workflow, self-hosted denial, predicate type) and returns a canned result built around a predicate `build-predicate.sh` produced from `toolchain.lock` at HEAD; every claim (theorem, module, commit, role of the digest, signer revision, runner, toolchain block, axiom policy) is then tampered with in turn and must be named in the rejection. Portable: git, jq, check-jsonschema. | check-jsonschema |
| [test-pipeline.sh](scripts/test-pipeline.sh) | The evaluate pipeline on the real pinned toolchain: a challenge with a dependency, then solutions that must pass (importing the challenge's definitions through a `require`; restating them) and be rejected (sorry, an extra axiom, a redefined constant, a different statement, a missing theorem, a wrong module), bad exports handed to the comparator jail, and a solution whose module runs shell commands at build time -- it must still pass, and nothing it did may have reached the host, the other workspace, the verifier binaries or the network, nor outlived its jail. | provisioned toolchain, bwrap, sudo |

To run them locally, provision the toolchain once (`sudo` installs into `/opt/lean` and `/opt/bin`)
and install `check-jsonschema` from the pinned requirements:

```sh
bash scripts/provision-toolchain.sh toolchain.lock
python3 -m venv .venv && .venv/bin/pip install --require-hashes --no-deps -r scripts/requirements.txt
PATH=".venv/bin:$PATH" bash scripts/test-pipeline.sh      # or any other suite
```

CI runs them in [test-scripts.yml](.github/workflows/test-scripts.yml) (jobs `scripts` and
`pipeline`, next to `lint`) and, in [e2e.yml](.github/workflows/e2e.yml), calls the reusable
workflow itself on the fixture packages kept in the orphan branches `fixtures/challenge` and
`fixtures/solution` of this repository -- a genuine attestation, signed on a GitHub-hosted runner
-- and then runs `verify.sh` against it as a verifier would, including the rejections only a real
Sigstore bundle can exercise (another theorem or module, the solution tree offered in the
challenge role, an untrusted workflow revision, a narrower axiom policy). The solution fixture
pins the challenge fixture's commit in its `lake-manifest.json`; the workflow inputs resolve the
branch heads at run time, so changing a fixture means updating its branch (and, for the
challenge, the solution's manifest). Rejections of dishonest solutions are not part of `e2e.yml`
-- a failing reusable-workflow job fails the run -- and are covered by `test-pipeline.sh`.
