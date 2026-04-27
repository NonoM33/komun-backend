# Komun MCP Server — plan de conception

Statut : brouillon, à valider par @renaud avant implémentation.

## Objectif

Exposer les données de Komun à des LLMs externes (Claude Desktop, Claude
Code, et à terme un LLM interne au-dessus de Groq) via un serveur MCP,
en réutilisant le modèle d'autorisation existant — **les accès du user
dans l'app sont les mêmes qu'à travers le MCP**.

Exemple :

- Un `:coproprietaire` peut demander au LLM « que dit le règlement sur
  les horaires de tonte ? » → ✅ (le MCP retourne les extraits pertinents
  du règlement).
- Ce même user demande « résume le PV de réunion CS du 3 mars » → ❌ si
  les PV CS sont scopés conseil seulement, le MCP ne lit rien.
- Un `:membre_cs` sur la même question → ✅.

## Architecture proposée

```
┌─────────────────┐   MCP (HTTP/SSE)     ┌──────────────────────────┐
│ LLM client      │◀────────────────────▶│ komun-mcp (Elixir Plug)  │
│  (Claude, etc.) │   X-Komun-Token: …   │  - tool discovery        │
└─────────────────┘                      │  - per-tool authz        │
                                         │  - réutilise contextes   │
                                         │    Documents, Incidents, │
                                         │    Doleances, Projects…  │
                                         └────────────┬─────────────┘
                                                      │ in-process
                                                      ▼
                                         ┌──────────────────────────┐
                                         │ KomunBackend (existing)  │
                                         │  - Repo / contextes      │
                                         │  - Guardian (reuse token)│
                                         └──────────────────────────┘
```

Option retenue : **endpoint MCP HTTP monté dans le Phoenix existant**,
pas un service séparé. Rationale :

- Le MCP parle aux mêmes données (`KomunBackend.Documents`,
  `KomunBackend.Incidents`, etc.). Une copie out-of-process créerait un
  second bug de dérive comme celui qui vient de casser l'assistant.
- Le token JWT Guardian déjà utilisé par le frontend sert d'auth
  utilisateur pour le MCP. Pas besoin de second système d'auth.
- Déploiement = 0 app Coolify de plus.

## Scope des outils MCP (v1)

Un user authentifié s'inscrit dans une seule résidence à la fois, donc
chaque tool prend un `building_id` (ou est lié à la résidence par défaut
du user). Tous les tools passent par un **plug d'autorisation** qui
vérifie :

1. Le token est valide (Guardian).
2. Le user est membre du building (`Buildings.member?`).
3. Le tool est autorisé pour le rôle (table ci-dessous).

| Tool                         | Rôles autorisés                                   | Backend appelé                    |
|------------------------------|---------------------------------------------------|-----------------------------------|
| `search_documents`           | tous (filtré par `Documents.context_for_ai/3`)    | `Documents.search_public_texts`   |
| `get_document`               | selon `is_public` + `category`                    | `Documents.get_if_visible`        |
| `list_incidents`             | tous (incidents = public dans le building)        | `Incidents.list_for_user`         |
| `list_doleances_open`        | tous (réclamations collectives = publiques)       | `Doleances.list_for_user`         |
| `get_regulation_excerpt`     | tous                                              | `Documents.context_for_ai`        |
| `list_projects`              | tous                                              | `Projects.list`                   |
| `list_council_votes`         | `:membre_cs`, `:president_cs`, syndic, admin      | `CouncilVotes.list`               |
| `read_council_pv`            | idem                                              | `Documents.list(:pv_cs)`          |
| `admin_search_users`         | `:super_admin`                                    | `Admin.search_users`              |

Le refus est explicite (`error: "not_authorized", scope: "<role>"`) pour
que le LLM ne passe pas son temps à retenter.

## Flux d'authentification

1. Depuis Claude Desktop, le user colle son token Guardian dans la conf
   MCP (header `Authorization: Bearer …`).
2. Le plug `KomunBackendWeb.MCP.Auth` décode le JWT, charge le user, et
   l'injecte dans les assigns (même logique que `Auth.Pipeline` actuel).
3. Chaque tool handler reçoit `user` + `params` et appelle le contexte
   métier correspondant.

Garde-fou côté token : prévoir un **scope MCP séparé** (`aud: "komun-mcp"`)
pour qu'un token volé depuis l'app ne serve pas au MCP — idem l'inverse.
→ Concrètement, un endpoint `/me/mcp-token` qui délivre un JWT signé
avec un audience dédié.

## Rate limiting & audit

- Rate limit global par user : par défaut 60 tool calls / heure, 600 /
  jour. Stocké dans Redis (déjà branché).
- Audit log (`mcp_audit_log` table) : `{user_id, tool, building_id,
  params_hash, status, inserted_at}`. Rétention 90 jours. Dashboard
  admin pour détecter l'exfiltration.

## Ce qui n'est PAS dans la v1

- Pas de tool `write_*` : la v1 est lecture seule. Pas de création
  d'incident ou de vote via MCP.
- Pas de conversation multi-user : chaque tool call est idempotent et
  stateless.
- Pas de streaming SSE côté MCP : on commence par MCP HTTP standard.

## Prochaines étapes (ordre d'implémentation)

1. **Lib MCP** — choisir / vendoriser une implémentation Elixir MCP (il
   en existe une poignée, on peut démarrer avec la nôtre si aucune ne
   tient la route — l'API MCP est ~500 lignes de JSON-RPC).
2. **Scope + audience JWT** : ajouter `mcp-token` endpoint + guardian
   strategy séparée.
3. **Plug authz + matrice de rôles** (fichier unique,
   `lib/komun_backend_web/mcp/authz.ex`).
4. **Tools read-only** (documents / incidents / doleances / projects)
   avec tests d'accès croisés.
5. **Audit log** + dashboard admin léger.
6. **Smoke depuis Claude Desktop** avec un compte super_admin puis un
   compte coproprietaire pour valider que le scope tient.

## Lien avec l'assistant in-app

L'assistant actuel (`KomunBackend.Assistant`) peut, dans un second temps,
router ses tool calls vers le même layer MCP — aujourd'hui il passe par
`Documents.context_for_ai/3`. Une fois le MCP mûr, l'assistant n'aura
plus besoin d'une couche séparée : même matrice d'autorisation partout.
