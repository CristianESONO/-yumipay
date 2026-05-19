import { createFileRoute, useNavigate, useSearch } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Loader2, Send } from "lucide-react";
import { toast } from "sonner";
import { formatXAF } from "@/lib/format";

export const Route = createFileRoute("/_app/send")({
  component: SendPage,
  validateSearch: (search: Record<string, unknown>) => {
    return {
      to: (search.to as string) || "",
    };
  },
});

const PRESETS = [5000, 10000, 25000, 50000];

function SendPage() {
  const navigate = useNavigate();
  const search = useSearch({ from: "/_app/send" });
  const [phone, setPhone] = useState(search.to || "");
  const [amount, setAmount] = useState<number | "">("");
  const [note, setNote] = useState("");
  const [loading, setLoading] = useState(false);
  const [recents, setRecents] = useState<any[]>([]);

  useEffect(() => {
    if (search.to) setPhone(search.to);
    loadRecents();
  }, [search.to]);

  async function loadRecents() {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    const { data } = await supabase
      .from("transactions")
      .select("recipient:profiles!transactions_recipient_id_fkey(full_name, phone)")
      .eq("sender_id", user.id)
      .order("created_at", { ascending: false })
      .limit(10);
    
    if (data) {
      // @ts-ignore
      const unique = Array.from(new Set(data.filter(t => t.recipient).map((t: any) => t.recipient.phone)))
        // @ts-ignore
        .map(phone => data.find((t: any) => t.recipient?.phone === phone).recipient);
      setRecents(unique.slice(0, 4));
    }
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!amount || amount <= 0) {
      toast.error("Introduce una cantidad válida");
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.rpc("send_money", {
        p_recipient_phone: phone.trim(),
        p_amount: Number(amount),
        p_note: note.trim() || undefined,
      });
      if (error) throw error;
      toast.success(`Enviado ${formatXAF(Number(amount))}`);
      navigate({ to: "/home" });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error";
      toast.error(msg);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <h1 className="font-display text-2xl font-bold text-foreground">Enviar dinero</h1>
      <p className="mt-1 text-sm text-muted-foreground">A cualquier usuario Yumi en Guinea Ecuatorial.</p>

      {recents.length > 0 && (
        <div className="mt-6">
          <p className="text-xs font-bold text-muted-foreground uppercase tracking-widest mb-3">Recientes</p>
          <div className="flex gap-3 overflow-x-auto pb-2 scrollbar-none">
            {recents.map((r: any) => (
              <button
                key={r.phone}
                type="button"
                onClick={() => setPhone(r.phone)}
                className="flex flex-col items-center gap-1.5 shrink-0"
              >
                <div className="grid h-12 w-12 place-items-center rounded-full bg-accent text-primary font-display font-bold">
                  {r.full_name.charAt(0)}
                </div>
                <span className="text-[10px] font-medium text-foreground max-w-[60px] truncate">{r.full_name}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      <form onSubmit={submit} className="mt-6 space-y-5">
        <label className="block">
          <span className="mb-1.5 block text-sm font-medium text-foreground">Teléfono del destinatario</span>
          <input
            required
            className="input"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder="+240 222 000 000"
            inputMode="tel"
          />
        </label>

        <div>
          <span className="mb-1.5 block text-sm font-medium text-foreground">Cantidad (XAF)</span>
          <input
            required
            className="input font-display text-2xl font-semibold"
            type="number"
            min={100}
            value={amount}
            onChange={(e) => setAmount(e.target.value ? Number(e.target.value) : "")}
            placeholder="0"
          />
          <div className="mt-3 flex flex-wrap gap-2">
            {PRESETS.map((p) => (
              <button
                type="button"
                key={p}
                onClick={() => setAmount(p)}
                className="rounded-full border border-border bg-card px-4 py-1.5 text-sm font-medium text-foreground transition hover:border-primary-glow hover:text-primary"
              >
                {formatXAF(p)}
              </button>
            ))}
          </div>
        </div>

        <label className="block">
          <span className="mb-1.5 block text-sm font-medium text-foreground">Nota (opcional)</span>
          <input
            className="input"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Comida, alquiler, regalo…"
            maxLength={100}
          />
        </label>

        <button
          type="submit"
          disabled={loading}
          className="inline-flex h-14 w-full items-center justify-center gap-2 rounded-2xl bg-primary font-display text-base font-semibold text-primary-foreground shadow-[var(--shadow-card)] transition active:scale-[0.98] disabled:opacity-60"
        >
          {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
          Confirmar envío
        </button>
      </form>
    </div>
  );
}
