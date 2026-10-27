import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { formatXAF } from "@/lib/format";
import { PinModal } from "@/components/PinModal";
import { QRCodeSVG } from "qrcode.react";
import { Banknote, X, Clock, AlertCircle, CheckCircle2, Loader2, ArrowRight } from "lucide-react";
import { toast } from "sonner";

interface WithdrawModalProps {
  isOpen: boolean;
  onClose: () => void;
  userBalance: number;
  onSuccess?: () => void;
}

const PRESETS = [2000, 5000, 10000, 25000];

export function WithdrawModal({ isOpen, onClose, userBalance, onSuccess }: WithdrawModalProps) {
  const [amount, setAmount] = useState<number | "">("");
  const [showPinModal, setShowPinModal] = useState(false);
  const [loading, setLoading] = useState(false);
  const [withdrawalResult, setWithdrawalResult] = useState<{
    code: string;
    amount_xaf: number;
    fee_xaf: number;
    expires_at: string;
  } | null>(null);
  const [timeLeft, setTimeLeft] = useState<number>(900); // 15 min en secondes

  useEffect(() => {
    let timer: any;
    if (withdrawalResult && timeLeft > 0) {
      timer = setInterval(() => {
        setTimeLeft((prev) => (prev > 0 ? prev - 1 : 0));
      }, 1000);
    }
    return () => clearInterval(timer);
  }, [withdrawalResult, timeLeft]);

  if (!isOpen) return null;

  const numAmount = Number(amount) || 0;
  const calculatedFee = numAmount >= 500 ? Math.max(100, Math.round(numAmount * 0.015)) : 0;
  const totalRequired = numAmount + calculatedFee;

  const handleStartWithdrawal = (e: React.FormEvent) => {
    e.preventDefault();
    if (numAmount < 500) {
      toast.error("El monto mínimo de retiro es de 500 XAF");
      return;
    }
    if (totalRequired > userBalance) {
      toast.error(`Saldo insuficiente. Necesitas ${formatXAF(totalRequired)} (incluye comisión)`);
      return;
    }
    setShowPinModal(true);
  };

  const handlePinSuccess = async (pin: string) => {
    setShowPinModal(false);
    setLoading(true);
    try {
      // @ts-ignore
      const { data, error } = await supabase.rpc("request_cash_out_v3", {
        p_amount: numAmount,
        p_pin: pin,
      });

      if (error) throw error;
      if (!data.ok) throw new Error(data.message || "Error al solicitar retiro");

      setWithdrawalResult(data as any);
      setTimeLeft(900);
      toast.success("Código de retiro generado con éxito");
      onSuccess?.();
    } catch (err: any) {
      toast.error(err.message || "Error al generar código de retiro");
    } finally {
      setLoading(false);
    }
  };

  const handleCancelCashOut = async () => {
    if (!withdrawalResult?.code) return;
    setLoading(true);
    try {
      // @ts-ignore
      const { data, error } = await supabase.rpc("cancel_cash_out", {
        p_code: withdrawalResult.code,
      });
      if (error) throw error;
      if (!data.ok) throw new Error(data.message || "Error al cancelar el retiro");
      toast.success("Retiro cancelado. Fondos devueltos a tu saldo.");
      handleClose();
      onSuccess?.();
    } catch (err: any) {
      toast.error(err.message || "Error al cancelar el retiro");
    } finally {
      setLoading(false);
    }
  };

  const handleClose = () => {
    setAmount("");
    setWithdrawalResult(null);
    onClose();
  };

  const formatTimer = (seconds: number) => {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${s < 10 ? "0" : ""}${s}`;
  };

  return (
    <>
      <div className="fixed inset-0 z-40 flex items-end sm:items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-in fade-in duration-200">
        <div className="w-full max-w-md rounded-3xl border border-border bg-card p-6 shadow-2xl animate-in slide-in-from-bottom-6 duration-200">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2 text-primary font-bold">
              <Banknote className="h-5 w-5" />
              <span className="text-xs uppercase tracking-wider">Retiro en Efectivo</span>
            </div>
            <button
              onClick={handleClose}
              className="grid h-8 w-8 place-items-center rounded-full bg-accent text-muted-foreground hover:text-foreground"
            >
              <X className="h-4 w-4" />
            </button>
          </div>

          {!withdrawalResult ? (
            <form onSubmit={handleStartWithdrawal} className="mt-5 space-y-4">
              <div>
                <h3 className="font-display text-xl font-bold text-foreground">Retirar en Punto Agente</h3>
                <p className="mt-1 text-xs text-muted-foreground">
                  Genera un código seguro para cobrar efectivo físico con cualquier agente Yumi autorizado.
                </p>
              </div>

              <div>
                <label className="block text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-2">
                  Cantidad a Retirar (XAF)
                </label>
                <input
                  required
                  type="number"
                  min={500}
                  step={100}
                  value={amount}
                  onChange={(e) => setAmount(e.target.value === "" ? "" : Number(e.target.value))}
                  placeholder="0"
                  className="input font-display text-2xl font-bold"
                />
              </div>

              <div className="flex flex-wrap gap-2">
                {PRESETS.map((p) => (
                  <button
                    key={p}
                    type="button"
                    onClick={() => setAmount(p)}
                    className="rounded-xl border border-border bg-card px-3 py-1.5 text-xs font-semibold text-foreground transition hover:border-primary hover:text-primary"
                  >
                    {formatXAF(p)}
                  </button>
                ))}
              </div>

              {numAmount >= 500 && (
                <div className="rounded-2xl border border-border/80 bg-accent/40 p-4 space-y-2 text-xs">
                  <div className="flex justify-between text-muted-foreground">
                    <span>Monto a recibir en efectivo:</span>
                    <span className="font-semibold text-foreground">{formatXAF(numAmount)}</span>
                  </div>
                  <div className="flex justify-between text-muted-foreground">
                    <span>Comisión de servicio (1.5%):</span>
                    <span className="font-semibold text-foreground">{formatXAF(calculatedFee)}</span>
                  </div>
                  <div className="pt-2 border-t border-border flex justify-between font-bold text-sm">
                    <span className="text-foreground">Total debitado:</span>
                    <span className="text-primary">{formatXAF(totalRequired)}</span>
                  </div>
                </div>
              )}

              <button
                type="submit"
                disabled={loading || numAmount < 500}
                className="mt-2 inline-flex h-14 w-full items-center justify-center gap-2 rounded-2xl bg-primary font-display text-base font-semibold text-primary-foreground shadow-md transition active:scale-[0.98] disabled:opacity-50"
              >
                {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <ArrowRight className="h-4 w-4" />}
                Continuar con PIN
              </button>
            </form>
          ) : (
            <div className="mt-5 text-center">
              <div className="inline-flex items-center gap-1.5 rounded-full bg-success/15 px-3 py-1 text-xs font-bold text-success mb-3">
                <CheckCircle2 className="h-4 w-4" /> Código de Retiro Activo
              </div>

              <h3 className="font-display text-2xl font-bold text-foreground">
                {formatXAF(withdrawalResult.amount_xaf)}
              </h3>
              <p className="text-xs text-muted-foreground mt-0.5">Muestra este código al agente para recibir tu dinero en mano</p>

              {/* Huge Code Display */}
              <div className="my-5 rounded-3xl border-2 border-primary/30 bg-primary/5 p-5">
                <p className="text-xs font-bold uppercase tracking-widest text-primary">Código de Retiro</p>
                <p className="mt-1 font-display text-4xl font-extrabold tracking-widest text-foreground">
                  {withdrawalResult.code}
                </p>
                <div className="mt-4 flex justify-center">
                  <div className="rounded-2xl bg-white p-3 shadow-md">
                    <QRCodeSVG
                      value={`YUMI_CASH_OUT:${withdrawalResult.code}:${withdrawalResult.amount_xaf}`}
                      size={130}
                    />
                  </div>
                </div>
              </div>

              {/* Timer */}
              <div className="flex items-center justify-center gap-2 text-xs font-semibold text-muted-foreground">
                <Clock className="h-4 w-4 text-primary" />
                <span>Expira en:</span>
                <span className="font-mono text-sm font-bold text-foreground">{formatTimer(timeLeft)}</span>
              </div>

              <div className="mt-6 space-y-2">
                <button
                  type="button"
                  onClick={handleClose}
                  className="w-full rounded-2xl bg-accent py-3.5 text-sm font-bold text-foreground hover:bg-border transition"
                >
                  Listo / Cerrar
                </button>
                <button
                  type="button"
                  onClick={handleCancelCashOut}
                  disabled={loading}
                  className="w-full rounded-2xl border border-destructive/30 py-2.5 text-xs font-semibold text-destructive hover:bg-destructive/10 transition"
                >
                  {loading ? "Cancelando..." : "Cancelar retiro y devolver fondos"}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>

      <PinModal
        isOpen={showPinModal}
        onClose={() => setShowPinModal(false)}
        onSuccess={handlePinSuccess}
        title="Confirma el retiro"
        description={`Introduce tu PIN para autorizar el retiro de ${formatXAF(numAmount)}`}
      />
    </>
  );
}
