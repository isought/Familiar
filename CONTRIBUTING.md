# Contributing

Thanks for helping. The project is early and changes quickly. For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Sign the CLA first

Every contribution needs a signed [Contributor License Agreement](CLA.md). On your first pull request, the CLA check posts a link; signing once covers all your future contributions.

You keep the rights to your work. The project gets the rights it needs to keep distributing it, including under other licenses in the future. If you contribute as part of your job, check that your employer allows it (CLA section 4).

## Build and test

```bash
./scripts/test.sh   # deterministic tests; no API key, login or permissions needed
./scripts/run.sh    # build and launch the app
```

The [developer guide](docs/development/guide.md) covers setup, signing and the source layout. Keep pull requests focused, and add tests for any change in behavior.

## Code from elsewhere

Only include code from other projects if its license is compatible with the Apache License 2.0. In the pull request:

- say where the code came from;
- add its notice to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md);
- add its license text to `licenses/`.

The same applies to any tool or binary the app bundles.

## AI-assisted contributions

These are welcome. You are responsible for everything you submit: read it, test it, and make sure it doesn't reproduce code you have no right to contribute. Mention the AI assistance in the pull request description.

## Name, icon and character

Contributing doesn't change who owns the project's brand. If you fork the project, follow [TRADEMARKS.md](TRADEMARKS.md) and rename it.

## Security problems

Please don't report security problems in public issues. Use GitHub's private vulnerability reporting, on the repository's **Security** tab.
