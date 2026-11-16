#!/usr/bin/env bash
# bk learn effect: veredicto por regla con un store de reglas, repos y PRs de prueba (no toca GitHub, tu vault ni tu caché).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }

export BARRILETE_VAULT="$TMP/vault"; mkdir -p "$BARRILETE_VAULT/agents"
export BK_RULES_CACHE="$TMP/cache"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# El store: barrilete-rules de prueba, en un repo git local
S="$TMP/store"; mkdir -p "$S/rules"
rule() {  # dir, id, frontmatter extra
  printf -- '---\nid: %s\n%b\n---\nRegla de %s.\n' "$2" "$3" "$2" >"$1/$2.md"
}
rule "$S/rules" baja      'status: accepted\napplies_to: [implementer]\nscope: [kit]\nclasses: [pr-metadata]\naccepted: 2026-11-10T00:00Z\ncheck: pr-metadata'
rule "$S/rules" no-baja   'status: accepted\napplies_to: "*"\nscope: "*"\nclasses: [stale-docs]\naccepted: 2026-11-10'
rule "$S/rules" sin-fecha 'status: accepted\napplies_to: "*"\nscope: "*"\nclasses: [uncovered-case]'
rule "$S/rules" sin-medir 'status: accepted\napplies_to: "*"\nscope: "*"\nclasses: []\naccepted: 2026-11-10'
rule "$S/rules" otro-repo 'status: accepted\napplies_to: "*"\nscope: [abra]\nclasses: [pr-metadata]\naccepted: 2026-11-10T00:00Z'
rule "$S/rules" pocos     'status: accepted\napplies_to: "*"\nscope: "*"\nclasses: [undecided-decision]\naccepted: 2026-11-10'
rule "$S/rules" vieja     'status: deprecated\napplies_to: "*"\nscope: "*"\nclasses: [stale-docs]\naccepted: 2026-11-10'
rule "$S/rules" de-nadie  'status: accepted\napplies_to: "*"\nscope: [otro-proyecto]\nclasses: [stale-docs]\naccepted: 2026-11-10'
printf -- '- id: pr-metadata\n  description: x\n- id: stale-docs\n  description: x\n- id: uncovered-case\n  description: x\n- id: undecided-decision\n  description: x\n' >"$S/classes.yml"
git -C "$S" init -q && git -C "$S" add -A && git -C "$S" commit -qm reglas
SHA=$(git -C "$S" rev-parse HEAD)
export BK_RULES_URL="$S"

# Dos proyectos: kit (con una regla propia y eventos de check) y abra
mkrepo() {
  mkdir -p "$TMP/$1/.barrilete"
  printf '# lock\nrepo=lautioliver/barrilete-rules\nsha=%s\n' "$SHA" >"$TMP/$1/.barrilete/rules.lock"
}
mkrepo kit; mkrepo abra
mkdir -p "$TMP/kit/.barrilete/rules"
printf -- '---\nid: latin1\nstatus: accepted\nscope: "*"\nclasses: [stale-docs]\naccepted: 2026-11-10\n---\nRegla con \xe1 en latin-1.\n' >"$TMP/kit/.barrilete/rules/latin1.md"
rule "$TMP/kit/.barrilete/rules" propia 'status: accepted\napplies_to: "*"\nscope: "*"\nclasses: [stale-docs]\naccepted: 2026-11-10'
mkdir -p "$TMP/kit/.barrilete/learning"
{
  echo '{"v": 0, "kind": "check_run", "check": "pr-metadata", "rule_id": "baja", "outcome": "pass"}'
  echo '{"v": 0, "kind": "check_run", "check": "pr-metadata", "rule_id": "baja", "outcome": "fail"}'
  echo '{"v": 0, "kind": "check_run", "check": "pr-metadata", "rule_id": "baja", "outcome": "pass"}'
  echo '{"v": 0, "kind": "check_run", "check": "pr-metadata", "rule_id": "baja", "outcome": "skipped"}'
  echo 'esto no es json'
  echo '{"kind": "check_run", "rule_id": ["baja"], "check": {"x": 1}, "outcome": "fail"}'
  echo '["check_run"]'
} >"$TMP/kit/.barrilete/learning/events.jsonl"
export BK_EFFECT_REPOS="$TMP/kit:$TMP/abra"

# Reviews: "metadatos" = pr-metadata etiquetado en código (`[pr-metadata] PR`); "docs" = sin etiqueta, docs desactualizados
# por palabra clave; "ok" = ronda sin hallazgos; "otro" = [other] explícito; "raro" = una etiqueta fuera de classes.yml
python3 - "$TMP/prs.json" <<'PY'
import json, sys
def body(kind):
    items = {"metadatos": "1. `[pr-metadata] PR`: hay 12/12 casos anotados y son 13.",
             "docs": "- El README no se actualizó: docs desactualizados.",
             "decision": "- **[undecided-decision] PR:** agrega una regla que el issue no trae.",
             "otro": "- **[other] PR:** el PR está en conflicto con main.",
             "raro": "- `[weak-test] t.sh:3`: el test mira poco.",
             "ok": ""}[kind]
    return "## Bloqueantes\n" + (items or "Ninguno.") + "\n\n## Sugerencias\n- nada\n"
def pr(n, created, kinds):
    return {"number": n, "createdAt": created, "reviews": [{"body": body(k)} for k in kinds]}
before = [pr(i, "2026-11-0%dT12:00:00Z" % (1 + i % 8), ["metadatos", "docs", "ok"]) for i in range(1, 5)]
before.append(pr(9, "2026-11-05T12:00:00Z", ["decision"]))
after = [pr(10 + i, "2026-11-1%dT12:00:00Z" % (1 + i % 8), ["docs", "docs", "ok"]) for i in range(4)]
after.append(pr(20, "2026-11-15T12:00:00Z", ["ok", "otro", "raro"]))
after[-1]["reviews"].append({"body": "un comentario suelto, sin secciones: no es una ronda"})
old = [pr(30, "2026-09-01T12:00:00Z", ["metadatos"] * 5)]   # fuera de la ventana de 30 días antes de aceptarla
json.dump({"kit": before + after + old, "abra": [pr(40, "2026-11-12T12:00:00Z", ["metadatos"])]}, open(sys.argv[1], "w"))
PY
export BK_EFFECT_PRS="$TMP/prs.json"
J=$(python3 "$ROOT/lib/effect.py" --json)
v() { jq -r --arg n "$1" '.rules[] | select(.rule == $n) | .verdict' <<<"$J"; }
f() { jq -r --arg n "$1" ".rules[] | select(.rule == \$n) | $2" <<<"$J"; }

check_eq "$(v baja)" baja "pr-metadata etiquetado entre comillas invertidas desaparece después de aceptarla: baja"
check_eq "$(f baja '.before.class')" 4 "antes: los 4 hallazgos \`[pr-metadata]\` cuentan como pr-metadata"
check_eq "$(f baja '.before.rounds')" 13 "antes: las 13 rondas de los 5 PRs de kit del mes (no las de hace 2 meses, ni la de abra)"
check_eq "$(f baja '.after.rounds')" 15 "después: también cuenta las rondas sin hallazgos"
check_eq "$(f baja '.check_runs | "\(.runs) \(.fails)"')" "3 1" "tasa de fallo del check: 1 de 3 (no cuenta skipped, líneas rotas ni un rule_id que no es texto)"
check_eq "$(v no-baja)" "no baja" "docs sube después: no baja"
check_eq "$(f no-baja '.repos | join(",")')" "kit,abra" "una regla de scope * se mide en todos los proyectos que la aplican"
check_eq "$(v sin-fecha)" "sin fecha" "sin accepted: no se mide y lo dice"
check_eq "$(v sin-medir)" "no se mide" "classes: [] no se mide"
check_eq "$(v otro-repo)" "poca muestra" "scope abra: solo mira las rondas de abra (1 ronda: poca muestra)"
check_eq "$(f otro-repo '.check_runs // "sin check"')" "sin check" "una regla sin check no muestra tasa de fallo"
check_eq "$(v pocos)" "pocos casos" "un solo hallazgo de la clase antes: pocos casos, no un veredicto"
check_eq "$(v propia)" "no baja" "la regla propia de .barrilete/rules/ del proyecto también se mide"
check_eq "$(v latin1)" "no baja" "una regla que no es UTF-8 se lee igual, sin traceback"
check_eq "$(jq -r '[.rules[] | select(.rule == "vieja" or .rule == "de-nadie")] | length' <<<"$J")" 0 \
  "no entran las deprecated ni las de un scope que ningún proyecto tiene"
J2=$(python3 "$ROOT/lib/effect.py" --json --days 3650)
check_eq "$(jq -r '.classes | "\(.other) \(.unknown | to_entries | map("\(.key)=\(.value)") | join(","))"' <<<"$J2")" \
  "1 weak-test=1" "other cuenta solo el [other] explícito; las etiquetas fuera de classes.yml se listan aparte"

# Sin eventos de check: "sin datos", no 0%
rm "$TMP/kit/.barrilete/learning/events.jsonl"
check_eq "$(python3 "$ROOT/lib/effect.py" --json | jq -r '.rules[] | select(.rule == "baja") | .check_runs.runs')" 0 \
  "sin eventos de check_run, la tasa queda sin datos"

# El store se clona una vez por SHA y después se lee de la caché aunque la URL ya no sirva
check_eq "$(ls "$BK_RULES_CACHE")" "$SHA" "la caché guarda el store en una carpeta por SHA"
check_eq "$(BK_RULES_URL="$TMP/no-existe" python3 "$ROOT/lib/effect.py" --json | jq -r '.rules | length')" 8 \
  "con la caché, no vuelve a clonar"

# Un SHA que el store no tiene: sale con un mensaje, no con un traceback
BAD=ffffffffffffffffffffffffffffffffffffffff
printf 'repo=lautioliver/barrilete-rules\nsha=%s\n' "$BAD" >"$TMP/abra/.barrilete/rules.lock"
OUT=$(python3 "$ROOT/lib/effect.py" --json 2>&1); RC=$?
check_eq "$RC" 1 "un SHA que no está en el store sale con 1"
check_eq "$(grep -c 'no pude traer lautioliver/barrilete-rules@fffffff' <<<"$OUT")" 1 "y dice qué no pudo traer"
check_eq "$(ls "$BK_RULES_CACHE" | grep -c tmp)" 0 "y no deja una carpeta a medio clonar"

# La etiqueta de clase de review-pr se reconoce en todas sus formas (deviations.finding_class)
fc() { (cd "$ROOT/lib" && python3 -c 'import sys; from deviations import finding_class; print(finding_class(sys.argv[1]))' "$1"); }
check_eq "$(fc '`[text-code-mismatch] a.py:1`: x')" text-code-mismatch "etiqueta en código"
check_eq "$(fc '#284: `[uncovered-case] b.sh:2`: x')" uncovered-case "etiqueta detrás del número de PR que agrega bk learn"
check_eq "$(fc '**[stale-docs] README:** x')" stale-docs "etiqueta en negrita"
check_eq "$(fc 'algo sin etiqueta que no dice nada')" other "sin etiqueta ni palabra clave: other"

# Un proyecto sin rules.lock no aporta reglas; el reporte se escribe igual
rm -f "$TMP/abra/.barrilete/rules.lock"
python3 "$ROOT/lib/effect.py" >/dev/null
check_eq "$(grep -c '^| `baja` | pr-metadata | kit |' "$BARRILETE_VAULT/agents/efecto.md")" 1 "escribe agents/efecto.md con una fila por regla"
check_eq "$(grep -c '^| `otro-repo` |' "$BARRILETE_VAULT/agents/efecto.md")" 0 "sin rules.lock, abra no aplica reglas"

echo "1..$N"; [ "$FAILED" -eq 0 ]
