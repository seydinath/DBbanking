Checkpoint: controle de concurrence + base de donnees distribuee
(scenario bancaire)

Ce document contient: (1) une explication claire des problemes de concurrence, (2) des
ordonnancements surs, (3) des exemples SQL (naif vs pessimiste vs optimiste),
(4) des exemples JavaScript/Node avec transactions SQL, et (5) un plan distribue
(fragmentation/replication/allocation).

Partie 1 - Gestion des transactions (conceptuelle)

Scenario: deux transferts s'executent en meme temps et touchent le meme compte.

1) Problemes de concurrence possibles (mise a jour perdue)
Une mise a jour perdue se produit lorsque deux transactions lisent le meme solde,
calculent des soldes differents, puis la seconde ecriture ecrase la premiere.

Ordonnancement non sur (exemple):

| Etape | T1 (A -> B)         | T2 (A -> C)         | Resultat                          |
|------|----------------------|---------------------|-----------------------------------|
| 1    | READ A = 1000         |                     |                                   |
| 2    |                      | READ A = 1000        | les deux lisent 1000              |
| 3    | WRITE A = 900         |                     |                                   |
| 4    |                      | WRITE A = 950        | ecrase T1 => mise a jour perdue   |

Solde final attendu: 850. L'ordonnancement ci-dessus peut laisser 950, donc il est non sur.

2) Mecanisme de verrouillage simple
Utiliser des verrous partages (S) pour lecture et exclusifs (X) pour ecriture.
Pour un transfert: prendre un verrou X sur les deux comptes (source et destination)
et les garder jusqu'au COMMIT (2PL strict).

3) Verrouillage pessimiste ou optimiste
Le pessimiste est recommande pour les transferts: la correction est critique et les conflits
sont plausibles. Il bloque avant la modification. L'optimiste reste correct mais impose
une detection de conflit et une logique de retry.

4) Ordonnancement sur avec X-lock

| Etape | T1              | T2              | Sur? |
|------|------------------|-----------------|------|
| 1    | X-LOCK(A)         |                 |      |
| 2    | READ/UPDATE A     |                 |      |
| 3    | COMMIT; UNLOCK(A) |                 |      |
| 4    |                  | X-LOCK(A)        |      |
| 5    |                  | READ/UPDATE A    |      |
| 6    |                  | COMMIT; UNLOCK(A)| OUI  |

SQL - Schema minimal + exemples de concurrence
SQL ecrit dans un style compatible PostgreSQL.

Schema + vues de fragmentation

```sql
-- Tables principales
CREATE TABLE customers (
  customer_id   UUID PRIMARY KEY,
  full_name     TEXT NOT NULL,
  phone         TEXT,
  address       TEXT,
  home_branch   TEXT NOT NULL CHECK (home_branch IN ('Tunis','Sousse','Sfax'))
);

-- Fragmentation verticale: auth separe
CREATE TABLE customer_auth (
  customer_id    UUID PRIMARY KEY REFERENCES customers(customer_id),
  email          TEXT UNIQUE NOT NULL,
  password_hash  TEXT NOT NULL,
  last_login_at  TIMESTAMP
);

CREATE TABLE accounts (
  account_id   UUID PRIMARY KEY,
  customer_id  UUID NOT NULL REFERENCES customers(customer_id),
  branch       TEXT NOT NULL CHECK (branch IN ('Tunis','Sousse','Sfax')),
  balance_cents BIGINT NOT NULL CHECK (balance_cents >= 0),
  version      BIGINT NOT NULL DEFAULT 1
);

CREATE TABLE ledger_transactions (
  tx_id           UUID PRIMARY KEY,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  from_account_id UUID NOT NULL REFERENCES accounts(account_id),
  to_account_id   UUID NOT NULL REFERENCES accounts(account_id),
  amount_cents    BIGINT NOT NULL CHECK (amount_cents > 0),
  branch          TEXT NOT NULL CHECK (branch IN ('Tunis','Sousse','Sfax'))
);

-- Fragmentation horizontale (vues par agence)
CREATE VIEW customers_tunis  AS SELECT * FROM customers WHERE home_branch = 'Tunis';
CREATE VIEW customers_sousse AS SELECT * FROM customers WHERE home_branch = 'Sousse';
CREATE VIEW customers_sfax   AS SELECT * FROM customers WHERE home_branch = 'Sfax';
```

Exemple 1 - Transfert naif (non sur)

```sql
BEGIN;
SELECT balance_cents FROM accounts WHERE account_id = :from;

-- l'app calcule: newBalance = oldBalance - amount
UPDATE accounts
SET balance_cents = :new_balance
WHERE account_id = :from;

UPDATE accounts
SET balance_cents = balance_cents + :amount
WHERE account_id = :to;

INSERT INTO ledger_transactions(tx_id, from_account_id, to_account_id, amount_cents, branch)
VALUES (:tx_id, :from, :to, :amount, :branch);
COMMIT;
```

Exemple 2 - Verrouillage pessimiste (SELECT ... FOR UPDATE)

```sql
BEGIN;
SELECT account_id, balance_cents
FROM accounts
WHERE account_id IN (:from, :to)
FOR UPDATE;

UPDATE accounts
SET balance_cents = balance_cents - :amount
WHERE account_id = :from AND balance_cents >= :amount;

UPDATE accounts
SET balance_cents = balance_cents + :amount
WHERE account_id = :to;

INSERT INTO ledger_transactions(tx_id, from_account_id, to_account_id, amount_cents, branch)
VALUES (:tx_id, :from, :to, :amount, :branch);
COMMIT;
```

Exemple 3 - Verrouillage optimiste (colonne version)

```sql
BEGIN;
SELECT balance_cents, version
FROM accounts
WHERE account_id = :from;

UPDATE accounts
SET balance_cents = balance_cents - :amount,
    version = version + 1
WHERE account_id = :from
  AND version = :expected_version
  AND balance_cents >= :amount;

UPDATE accounts
SET balance_cents = balance_cents + :amount,
    version = version + 1
WHERE account_id = :to
  AND version = :expected_version_to;

INSERT INTO ledger_transactions(tx_id, from_account_id, to_account_id, amount_cents, branch)
VALUES (:tx_id, :from, :to, :amount, :branch);
COMMIT;
```

JavaScript (Node.js) - Exemples d'API minimales

```js
// npm i express pg
import express from "express";
import { Pool } from "pg";
import crypto from "crypto";

const app = express();
app.use(express.json());

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

// Helper: executer une fonction dans une transaction SQL
async function withTx(fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const res = await fn(client);
    await client.query("COMMIT");
    return res;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

app.get("/balance/:accountId", async (req, res) => {
  const { accountId } = req.params;
  const r = await pool.query(
    "SELECT account_id, balance_cents FROM accounts WHERE account_id = $1",
    [accountId]
  );
  if (r.rowCount === 0) return res.status(404).json({ error: "ACCOUNT_NOT_FOUND" });
  res.json(r.rows[0]);
});

// POST /transfer (pessimiste)
app.post("/transfer", async (req, res) => {
  const { fromAccountId, toAccountId, amountCents, branch } = req.body;
  if (!fromAccountId || !toAccountId || !Number.isInteger(amountCents) || amountCents <= 0) {
    return res.status(400).json({ error: "INVALID_INPUT" });
  }
  try {
    const result = await withTx(async (client) => {
      const ids = [fromAccountId, toAccountId].sort();
      await client.query(
        "SELECT account_id FROM accounts WHERE account_id = ANY($1::uuid[]) FOR UPDATE",
        [ids]
      );

      const w = await client.query(
        "UPDATE accounts SET balance_cents = balance_cents - $1 WHERE account_id = $2 AND balance_cents >= $1 RETURNING balance_cents",
        [amountCents, fromAccountId]
      );
      if (w.rowCount === 0) return { ok: false, error: "INSUFFICIENT_FUNDS" };

      await client.query(
        "UPDATE accounts SET balance_cents = balance_cents + $1 WHERE account_id = $2",
        [amountCents, toAccountId]
      );

      const txId = crypto.randomUUID();
      await client.query(
        "INSERT INTO ledger_transactions(tx_id, from_account_id, to_account_id, amount_cents, branch) VALUES ($1, $2, $3, $4, $5)",
        [txId, fromAccountId, toAccountId, amountCents, branch ?? "Tunis"]
      );
      return { ok: true, txId };
    });

    if (!result.ok) return res.status(409).json(result);
    res.status(201).json(result);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "INTERNAL_ERROR" });
  }
});

// POST /transfer-optimistic (optionnel)
app.post("/transfer-optimistic", async (req, res) => {
  const { fromAccountId, toAccountId, amountCents, branch } = req.body;
  const MAX_RETRIES = 3;
  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    try {
      const out = await withTx(async (client) => {
        const fromRow = await client.query(
          "SELECT balance_cents, version FROM accounts WHERE account_id=$1",
          [fromAccountId]
        );
        const toRow = await client.query(
          "SELECT version FROM accounts WHERE account_id=$1",
          [toAccountId]
        );
        if (fromRow.rowCount === 0 || toRow.rowCount === 0) {
          return { ok: false, error: "ACCOUNT_NOT_FOUND" };
        }
        const { balance_cents: bal, version: vFrom } = fromRow.rows[0];
        const { version: vTo } = toRow.rows[0];
        if (bal < amountCents) return { ok: false, error: "INSUFFICIENT_FUNDS" };

        const u1 = await client.query(
          "UPDATE accounts SET balance_cents = balance_cents - $1, version = version + 1 WHERE account_id=$2 AND version=$3",
          [amountCents, fromAccountId, vFrom]
        );
        const u2 = await client.query(
          "UPDATE accounts SET balance_cents = balance_cents + $1, version = version + 1 WHERE account_id=$2 AND version=$3",
          [amountCents, toAccountId, vTo]
        );
        if (u1.rowCount === 0 || u2.rowCount === 0) {
          throw new Error("OPTIMISTIC_CONFLICT");
        }

        const txId = crypto.randomUUID();
        await client.query(
          "INSERT INTO ledger_transactions(tx_id, from_account_id, to_account_id, amount_cents, branch) VALUES ($1, $2, $3, $4, $5)",
          [txId, fromAccountId, toAccountId, amountCents, branch ?? "Tunis"]
        );
        return { ok: true, txId };
      });

      if (!out.ok) return res.status(409).json(out);
      return res.status(201).json({ ...out, attempt });
    } catch (e) {
      if (String(e?.message) === "OPTIMISTIC_CONFLICT" && attempt < MAX_RETRIES) {
        continue;
      }
      return res.status(500).json({ error: "INTERNAL_ERROR", details: String(e?.message ?? e) });
    }
  }
});

app.listen(3000, () => console.log("API on http://localhost:3000"));
```

Partie 2 - Planification de base de donnees distribuee (niveau eleve)

Agences: Tunis, Sousse, Sfax. Objectif: operations locales rapides avec coherence globale.

Fragmentation horizontale (table Clients)
- Clients_Tunis: home_branch = 'Tunis'
- Clients_Sousse: home_branch = 'Sousse'
- Clients_Sfax: home_branch = 'Sfax'

Fragmentation verticale
- Separer un champ sensible (email ou login_hash) dans une table CustomerAuth liee par customer_id.

Replication entre agences (quoi + pourquoi)
- Repliquer les infos client de base (customer_id, nom, statut) pour identifier un client partout.
- Replication possible des soldes pour disponibilite, avec ecritures fortement coherentes.
- Historique des transactions: volumineux, replication totale couteuse.

Allocation de l'historique des transactions
- Allocation dynamique: ecrire localement dans l'agence d'origine, puis consolider vers un
  stockage central pour reporting/audit. Cela reduit le trafic inter-agences.
