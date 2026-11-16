// El uso de cada computadora para la barra de abajo: CPU y memoria de esta máquina y de las otras conectadas
// (las de `hc machine ls`), para ver de un vistazo cuál está cargada antes de mandarle más trabajo.
// Es el modelo solo, sin dibujo ni Herdr. La lectura es un sh que corre igual en macOS y en Linux, sin nada que
// instalar: la barra lo corre en cada máquina con exec(…, { on }).

// Imprime una línea: "cpu_sumada núcleos memoria_total memoria_usada nombre" (cpu_sumada: 100 por núcleo ocupado;
// la memoria, en bytes). macOS: la suma de los %cpu de los procesos, y usada = activa + cableada + comprimida.
// Linux: lo ocupado en medio segundo según /proc/stat (ahí el %cpu de ps es el promedio de toda la vida del
// proceso, no lo de ahora), y usada = total − disponible.
export const READ = String.raw`export LC_ALL=C
if [ "$(uname -s)" = Darwin ]; then
  cpu=$(ps -A -o %cpu= | awk '{s+=$1} END {print s+0}')
  n=$(sysctl -n hw.ncpu); t=$(sysctl -n hw.memsize)
  u=$(vm_stat | awk '/page size of/ {p=$8} /Pages active/ {a=$3} /Pages wired down/ {w=$4} /occupied by compressor/ {c=$5} END {gsub(/\./,"",a); gsub(/\./,"",w); gsub(/\./,"",c); printf "%.0f", (a+w+c)*p}')
else
  stat() { awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat; }
  n=$(nproc); set -- $(stat); sleep 0.5; set -- "$@" $(stat)
  cpu=$(awk -v t1="$1" -v i1="$2" -v t2="$3" -v i2="$4" -v n="$n" 'BEGIN { d = t2 - t1; print (d > 0 ? 100 * n * (d - (i2 - i1)) / d : 0) }')
  t=$(awk '/^MemTotal/ {printf "%.0f", $2*1024}' /proc/meminfo)
  u=$(awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {printf "%.0f", (t-a)*1024}' /proc/meminfo)
fi
echo "$cpu $n $t $u $(hostname -s 2>/dev/null || uname -n | cut -d. -f1)"`;

export const EVERY = 5000;    // cada cuánto se lee
export const STALE = 20000;   // una lectura más vieja que esto no se muestra (la máquina se fue, o no contesta)
export const HIGH = 85;       // desde acá, en rojo

const pct = (x) => Math.max(0, Math.min(100, Math.round(x)));

// La lectura en porcentajes: { cpu, mem, host }, o null si no se entiende
export function parse(out) {
  const [cpu, cores, total, used, host] = String(out ?? "").trim().split(/\s+/);
  const n = [cpu, cores, total, used].map(Number);
  if (n.some((x) => !Number.isFinite(x)) || used === undefined || n[1] <= 0 || n[2] <= 0) return null;
  return { cpu: pct(n[0] / n[1]), mem: pct((100 * n[3]) / n[2]), host: host || null };
}

// El nombre para la barra: uno largo (MacBook-Pro-de-Luciano) queda en su primera parte; el completo va en el tooltip
export const LONG = 14;
export function short(name) {
  if (name.length <= LONG) return name;
  const head = name.split(/[-._ ]/)[0];
  return head.length >= 3 && head.length <= LONG ? head : name.slice(0, LONG - 2) + "…";
}

// A quién se le pregunta: esta máquina (null) y las conectadas que están o pueden estar
export function targets(machines) {
  return [...new Set([null, ...machines.filter((m) => m.name && m.layout !== "unavailable").map((m) => m.name)])];
}

// Lo que se muestra: una fila por máquina con una lectura fresca. `read`: máquina ("" = esta) → { cpu, mem, host, at }
export function rows(names, read, now) {
  return names.map((m) => ({ m, r: read[m ?? ""] })).filter(({ r }) => r && now - r.at <= STALE)
    .map(({ m, r }) => ({ key: m ?? "", name: m ?? r.host ?? "esta", cpu: r.cpu, mem: r.mem, high: r.cpu >= HIGH || r.mem >= HIGH }));
}
