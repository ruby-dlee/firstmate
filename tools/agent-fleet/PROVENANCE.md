# Provenance

Agent Fleet was developed as a provider-neutral local component before its source was imported into the public Firstmate repository.
The initial imported tree was the exact tracked tree from standalone commit `863188085af088371cf1e2b29e800f1ff1533e27`.
No provider credentials, Fleet state, build outputs, caches, or virtual environments were imported.
Version 0.2.0 adds the post-import safety work in this repository: remote
identity-set verification, Desktop/base identity anchors, provider maintenance
serialization, staged and journaled Codex enrollment, fail-closed process
ownership, and login/logout isolation. After this import,
`tools/agent-fleet` in `ruby-dlee/firstmate` is the canonical source and
standalone release boundary.

The original standalone history was authored by Dongkeun Lee:

| Commit | Date | Subject |
| --- | --- | --- |
| `333805f651c695cee4c7eab2a04004dcdee34eae` | 2026-07-13 | Initialize Agent Fleet repository |
| `de02ab1a5195a9c39dc4a1b942a5c1816cbf778d` | 2026-07-13 | Add dynamic local agent account routing |
| `7f29a4e8aa10c851dcb1ea76a37615775c3af425` | 2026-07-13 | Verify Fleet integration health |
| `33c8552c32ede7eaad65b50622fa3768365b6000` | 2026-07-13 | Preserve unavailable quota status |
| `2392f8cbbaba064c2d439a16efaba0bdef79d68b` | 2026-07-13 | Make Fleet lifecycle recovery safe |
| `5eecf0d6ed490dcb12127fd91a789db2d5ae1a67` | 2026-07-13 | Reserve sticky account recovery |
| `add094815d4fa159ff6a86821484ba81ee4d4294` | 2026-07-17 | Fail closed on Fleet authentication readiness |
| `863188085af088371cf1e2b29e800f1ff1533e27` | 2026-07-17 | Keep Fleet version metadata aligned |

The component is licensed under the MIT license in [LICENSE](LICENSE).
