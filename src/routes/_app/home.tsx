import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { ArrowUpRight, ArrowDownLeft, Plus, Send, Eye, EyeOff } from "lucide-react";
import { formatXAF, initials } from "@/lib/format";
import { TransactionDetail } from "@/components/TransactionDetail";

export const Route = createFileRoute("/_app/home")({
  component: HomePage,
});

type Profile = { id: string; full_name: string; phone: string; balance_xaf: number };
type Tx = {
  id: string;
  amount_xaf: number;
  note: string | null;
  created_at: string;
  sender_id: string;
  recipient_id: string;
  status?: string;
  sender: { full_name: string } | null;
  recipient: { full_name: string } | null;
};

function HomePage() {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [txs, setTxs] = useState<Tx[]>([]);
  const [hideBalance, setHideBalance] = useState(false);
  const [selectedTx, setSelectedTx] = useState<any>(null);

  async function load() {
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) return;
    const { data: p } = await supabase.from("profiles").select("*").eq("id", u.user.id).maybeSingle();
    setProfile(p as Profile | null);
    const { data: t } = await supabase
      .from("transactions")
      .select("id, amount_xaf, note, created_at, sender_id, recipient_id, status, sender:profiles!transactions_sender_id_fkey(full_name), recipient:profiles!transactions_recipient_id_fkey(full_name)")
      .order("created_at", { ascending: false })
      .limit(5);
    setTxs((t as unknown as Tx[]) ?? []);
  }

  useEffect(() => {
    load();

    // Subscribe to real-time changes on the profile
    const channel = supabase
      .channel("profile-updates")
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "profiles" },
        (payload) => {
          if (profile && payload.new.id === profile.id) {
            setProfile(payload.new as Profile);
          }
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [profile?.id]);

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm text-muted-foreground">Hola,</p>
          <p className="font-display text-lg font-semibold text-foreground">
            {profile?.full_name ?? "..."}
          </p>
        </div>
        <div className="grid h-11 w-11 place-items-center rounded-full bg-accent font-display font-semibold text-primary">
          {profile ? initials(profile.full_name) : "·"}
        </div>
      </div>

      <div
        className="mt-6 overflow-hidden rounded-3xl p-6 text-primary-foreground shadow-[var(--shadow-card)]"
        style={{ background: "var(--gradient-card)" }}
      >
        <div className="flex items-center justify-between">
          <p className="text-xs uppercase tracking-wider text-primary-foreground/60">Saldo disponible</p>
          <button onClick={() => setHideBalance(!hideBalance)} className="text-primary-foreground/70 hover:text-primary-foreground">
            {hideBalance ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        </div>
        <p className="mt-3 font-display text-4xl font-bold tracking-tight">
          {hideBalance ? "•••••• XAF" : formatXAF(profile?.balance_xaf ?? 0)}
        </p>
        <p className="mt-1 text-sm text-primary-foreground/70">{profile?.phone}</p>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-3">
        <Link
          to="/send"
          className="flex items-center justify-center gap-2 rounded-2xl bg-primary py-4 font-display font-semibold text-primary-foreground shadow-[var(--shadow-soft)] active:scale-[0.98]"
        >
          <Send className="h-4 w-4" /> Enviar
        </Link>
        <button
          className="flex items-center justify-center gap-2 rounded-2xl border border-border bg-card py-4 font-display font-semibold text-foreground active:scale-[0.98]"
          onClick={() => alert("Pronto: recarga vía operadores móviles")}
        >
          <Plus className="h-4 w-4" /> Recargar
        </button>
      </div>

      <div className="mt-8 flex items-center justify-between">
        <h2 className="font-display text-lg font-semibold text-foreground">Movimientos</h2>
        <Link to="/history" className="text-sm text-primary hover:underline">
          Ver todo
        </Link>
      </div>

      <div className="mt-3 space-y-2">
        {txs.length === 0 && (
          <p className="rounded-2xl border border-dashed border-border bg-card/50 p-6 text-center text-sm text-muted-foreground">
            Aún no hay movimientos. Envía tu primer pago.
          </p>
        )}
        {txs.map((tx) => (
          <TxRow key={tx.id} tx={tx} meId={profile?.id ?? ""} onClick={() => setSelectedTx(tx)} />
        ))}
      </div>

      {selectedTx && (
        <TransactionDetail 
          transaction={selectedTx} 
          onClose={() => setSelectedTx(null)} 
          onUpdate={load}
        />
      )}
    </div>
  );
}

export function TxRow({ tx, meId, onClick }: { tx: any; meId: string; onClick?: () => void }) {
  const outgoing = tx.sender_id === meId;
  const other = outgoing ? tx.recipient?.full_name : tx.sender?.full_name;
  return (
    <button 
      onClick={onClick}
      className="flex w-full items-center gap-3 rounded-2xl border border-border bg-card p-3.5 text-left transition active:scale-[0.98]"
    >
      <div
        className={`grid h-10 w-10 place-items-center rounded-full ${
          outgoing ? "bg-destructive/10 text-destructive" : "bg-success/15 text-success"
        }`}
      >
        {outgoing ? <ArrowUpRight className="h-5 w-5" /> : <ArrowDownLeft className="h-5 w-5" />}
      </div>
      <div className="min-w-0 flex-1">
        <p className="truncate font-medium text-foreground">
          {outgoing ? "A " : "De "}
          {other ?? "Usuario"}
        </p>
        <p className="truncate text-[10px] text-muted-foreground uppercase tracking-widest font-bold">
          {tx.status} • {new Date(tx.created_at).toLocaleDateString("es-ES", { day: "2-digit", month: "short" })}
        </p>
      </div>
      <p className={`font-display font-semibold ${outgoing ? "text-foreground" : "text-success"}`}>
        {outgoing ? "−" : "+"}
        {formatXAF(tx.amount_xaf)}
      </p>
    </button>
  );
}
