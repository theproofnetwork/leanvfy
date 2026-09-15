# leanvfy end-to-end fixture: solution

A minimal solution Lake package for `.github/workflows/e2e.yml` of
[theproofnetwork/leanvfy](https://github.com/theproofnetwork/leanvfy): it
`require`s the challenge fixture (branch `fixtures/challenge`, pinned by commit
in `lake-manifest.json`), imports its definitions and proves `Challenge.main`
in the module `Solution`.
