import { useState } from "react";
import { Lock, X, Check, Delete } from "lucide-react";

interface PinModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: (pin: string) => void;
  title?: string;
  description?: string;
}

export function PinModal({
  isOpen,
  onClose,
  onSuccess,
  title = "Introduce tu código PIN",
  description = "Autoriza esta operación bancaria con tu clave secreta de 4 dígitos",
}: PinModalProps) {
  const [pin, setPin] = useState("");

  if (!isOpen) return null;

  const handleDigit = (digit: string) => {
    if (pin.length < 4) {
      const nextPin = pin + digit;
      setPin(nextPin);
      if (nextPin.length === 4) {
        setTimeout(() => {
          onSuccess(nextPin);
          setPin("");
        }, 150);
      }
    }
  };

  const handleDelete = () => {
    setPin(pin.slice(0, -1));
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-in fade-in duration-200">
      <div className="w-full max-w-sm rounded-3xl border border-border bg-card p-6 shadow-2xl animate-in slide-in-from-bottom-6 duration-200">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2 text-primary font-bold">
            <Lock className="h-5 w-5" />
            <span className="text-xs uppercase tracking-wider">Seguridad Yumi</span>
          </div>
          <button
            onClick={() => {
              setPin("");
              onClose();
            }}
            className="grid h-8 w-8 place-items-center rounded-full bg-accent text-muted-foreground hover:text-foreground"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        <div className="mt-4 text-center">
          <h3 className="font-display text-xl font-bold text-foreground">{title}</h3>
          <p className="mt-1 text-xs text-muted-foreground">{description}</p>
        </div>

        {/* PIN Indicators */}
        <div className="my-6 flex justify-center gap-4">
          {[0, 1, 2, 3].map((idx) => (
            <div
              key={idx}
              className={`h-4 w-4 rounded-full border-2 transition-all duration-200 ${
                idx < pin.length
                  ? "border-primary bg-primary scale-110 shadow-sm shadow-primary/50"
                  : "border-muted-foreground/30 bg-muted/20"
              }`}
            />
          ))}
        </div>

        {/* Virtual Keypad */}
        <div className="grid grid-cols-3 gap-3">
          {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((num) => (
            <button
              key={num}
              type="button"
              onClick={() => handleDigit(num)}
              className="flex h-14 items-center justify-center rounded-2xl bg-accent/70 font-display text-xl font-bold text-foreground transition active:scale-95 active:bg-primary active:text-white"
            >
              {num}
            </button>
          ))}
          <div className="grid place-items-center">
            <button
              type="button"
              onClick={() => {
                setPin("");
                onClose();
              }}
              className="text-xs font-semibold text-muted-foreground hover:text-foreground"
            >
              Cancelar
            </button>
          </div>
          <button
            type="button"
            onClick={() => handleDigit("0")}
            className="flex h-14 items-center justify-center rounded-2xl bg-accent/70 font-display text-xl font-bold text-foreground transition active:scale-95 active:bg-primary active:text-white"
          >
            0
          </button>
          <button
            type="button"
            onClick={handleDelete}
            disabled={pin.length === 0}
            className="flex h-14 items-center justify-center rounded-2xl bg-accent/70 text-foreground transition active:scale-95 disabled:opacity-40"
          >
            <Delete className="h-5 w-5" />
          </button>
        </div>
      </div>
    </div>
  );
}
