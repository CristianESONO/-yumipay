import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { TxRow } from "./home";
import { TransactionDetail } from "@/components/TransactionDetail";

export const Route = createFileRoute("/_app/history")({
  component: HistoryPage,
});

type Tx = any;

function HistoryPage() {
  const [txs, setTxs] = useState<Tx[]>([]);
  const [meId, setMeId] = useState("");
  const [selectedTx, setSelectedTx] = useState<Tx | null>(null);

  const loadData = async () => {
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) return;
    setMeId(u.user.id);
    const { data } = await supabase
      .from("transactions")
      .select("id, amount_xaf, note, created_at, sender_id, recipient_id, status, sender:profiles!transactions_sender_id_fkey(full_name), recipient:profiles!transactions_recipient_id_fkey(full_name)")
      .order("created_at", { ascending: false });
    setTxs((data as unknown as Tx[]) ?? []);
  };

  useEffect(() => {
    loadData();
  }, []);

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <h1 className="font-display text-2xl font-bold text-foreground">Historial</h1>
      <p className="mt-1 text-sm text-muted-foreground">Todos tus movimientos.</p>

      <div className="mt-6 space-y-2">
        {txs.length === 0 && (
          <p className="rounded-2xl border border-dashed border-border bg-card/50 p-6 text-center text-sm text-muted-foreground">
            Sin movimientos todavía.
          </p>
        )}
        {txs.map((tx) => (
          <TxRow key={tx.id} tx={tx} meId={meId} onClick={() => setSelectedTx(tx)} />
        ))}
      </div>

      {selectedTx && (
        <TransactionDetail 
          transaction={selectedTx} 
          onClose={() => setSelectedTx(null)} 
          onUpdate={loadData}
        />
      )}
    </div>
  );
}
