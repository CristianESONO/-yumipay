export function formatXAF(amount: number | bigint): string {
  const n = typeof amount === "bigint" ? Number(amount) : amount;
  return new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 0 }).format(n) + " XAF";
}

export function formatPhone(p: string): string {
  return p.replace(/(\+?\d{3})(\d{3})(\d{3})/, "$1 $2 $3");
}

export function initials(name: string): string {
  return name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");
}
