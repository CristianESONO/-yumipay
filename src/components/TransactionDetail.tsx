import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { formatXAF } from "@/lib/format";
import { 
  X, 
  ArrowUpRight, 
  ArrowDownLeft, 
  Clock, 
  AlertCircle, 
  CheckCircle2, 
  XCircle,
  RotateCcw,
  MessageSquare,
  Loader2
} from "lucide-react";
import { toast } from "sonner";

interface TransactionDetailProps {
  transaction: any;
  onClose: () => void;
  onUpdate: () => void;
}

export function TransactionDetail({ transaction, onClose, onUpdate }: TransactionDetailProps) {
  const [loading, setLoading] = useState(false);
  const [currentUser, setCurrentUser] = useState<string | null>(null);
  const [reversalNote, setReversalNote] = useState("");
  const [showReversalForm, setShowReversalForm] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setCurrentUser(data.user?.id || null));
  }, []);

  const isSender = currentUser === transaction.sender_id;
  const isCompleted = transaction.status === "completed";
  const createdDate = new Date(transaction.created_at);
  const diffHours = (new Date().getTime() - createdDate.getTime()) / (1000 * 60 * 60);
  const canCancelDirectly = isSender && isCompleted && diffHours < 24;
  const canRequestReversal = isSender && isCompleted && diffHours >= 24;

  async function handleCancel() {
    setLoading(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("cancel_transaction", {
        p_transaction_id: transaction.id
      });
      if (error) throw error;
      toast.success("Transacción anulada correctamente");
      onUpdate();
      onClose();
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }

  async function handleRequestReversal() {
    if (!reversalNote) return toast.error("Por favor, explica el motivo");
    setLoading(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("request_reversal", {
        p_transaction_id: transaction.id,
        p_note: reversalNote
      });
      if (error) throw error;
      toast.success("Solicitud enviada al banco");
      onUpdate();
      onClose();
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 backdrop-blur-sm sm:items-center p-4">
      <div className="w-full max-w-md animate-in fade-in slide-in-from-bottom-5 rounded-t-[2.5rem] bg-background p-8 sm:rounded-[2.5rem] shadow-2xl ring-1 ring-border">
        <div className="flex items-center justify-between mb-8">
          <h2 className="font-display text-xl font-bold text-foreground">Detalle de Operación</h2>
          <button onClick={onClose} className="rounded-full bg-accent/50 p-2 text-muted-foreground hover:bg-accent">
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex flex-col items-center text-center">
          <div className={`grid h-16 w-16 place-items-center rounded-2xl ${isSender ? 'bg-destructive/10 text-destructive' : 'bg-success/10 text-success'}`}>
            {isSender ? <ArrowUpRight className="h-8 w-8" /> : <ArrowDownLeft className="h-8 w-8" />}
          </div>
          <p className="mt-4 font-display text-3xl font-bold text-foreground">
            {isSender ? "-" : "+"}{formatXAF(transaction.amount_xaf)}
          </p>
          <div className="mt-2 flex items-center gap-1.5 rounded-full bg-accent/50 px-3 py-1 text-[10px] font-bold uppercase tracking-widest text-muted-foreground">
            {transaction.status === 'completed' && <CheckCircle2 className="h-3 w-3 text-success" />}
            {transaction.status === 'cancelled' && <XCircle className="h-3 w-3 text-destructive" />}
            {transaction.status === 'reversal_pending' && <Clock className="h-3 w-3 text-warning" />}
            {transaction.status}
          </div>
        </div>

        <div className="mt-8 space-y-4 rounded-3xl border border-border bg-card/50 p-6">
          <div className="flex justify-between text-xs">
            <span className="text-muted-foreground">ID Transacción</span>
            <span className="font-mono font-medium text-foreground uppercase">{transaction.id.slice(0, 8)}...</span>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-muted-foreground">Fecha y Hora</span>
            <span className="font-medium text-foreground">{createdDate.toLocaleString()}</span>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-muted-foreground">{isSender ? "Para" : "De"}</span>
            <span className="font-bold text-foreground">
              {isSender ? transaction.recipient?.full_name : transaction.sender?.full_name}
            </span>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-muted-foreground">Concepto</span>
            <span className="font-medium text-foreground italic">"{transaction.note || 'Sin concepto'}"</span>
          </div>
        </div>

        <div className="mt-8 space-y-3">
          {canCancelDirectly && (
            <button
              onClick={handleCancel}
              disabled={loading}
              className="flex w-full items-center justify-center gap-2 rounded-2xl bg-destructive py-4 text-sm font-bold text-destructive-foreground shadow-lg shadow-destructive/20 transition active:scale-[0.98] disabled:opacity-50"
            >
              <RotateCcw className="h-4 w-4" />
              Anular Transacción (Ventana 24h)
            </button>
          )}

          {canRequestReversal && !showReversalForm && (
            <button
              onClick={() => setShowReversalForm(true)}
              className="flex w-full items-center justify-center gap-2 rounded-2xl bg-accent py-4 text-sm font-bold text-foreground transition active:scale-[0.98]"
            >
              <AlertCircle className="h-4 w-4" />
              Solicitar Reversión Bancaria
            </button>
          )}

          {showReversalForm && (
            <div className="space-y-3 animate-in fade-in slide-in-from-top-2">
              <textarea
                placeholder="Explica el motivo del error para que el banco lo revise..."
                className="w-full rounded-2xl border border-border bg-background p-4 text-sm focus:border-primary focus:outline-none"
                rows={3}
                value={reversalNote}
                onChange={(e) => setReversalNote(e.target.value)}
              />
              <div className="flex gap-2">
                <button
                  onClick={handleRequestReversal}
                  disabled={loading}
                  className="flex-1 rounded-xl bg-primary py-3 text-xs font-bold text-primary-foreground disabled:opacity-50"
                >
                  {loading ? <Loader2 className="h-4 w-4 animate-spin mx-auto" /> : "Enviar Solicitud"}
                </button>
                <button
                  onClick={() => setShowReversalForm(false)}
                  className="rounded-xl bg-accent px-6 py-3 text-xs font-bold text-foreground"
                >
                  Cancelar
                </button>
              </div>
            </div>
          )}

          <p className="text-center text-[10px] text-muted-foreground leading-relaxed">
            CCEI Bank Guinea Ecuatorial - Auditoría y Seguridad de Red
          </p>
        </div>
      </div>
    </div>
  );
}
