import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { QRCodeSVG } from "qrcode.react";
import { Html5QrcodeScanner } from "html5-qrcode";
import { QrCode, Scan, X, Loader2 } from "lucide-react";

export const Route = createFileRoute("/_app/qr")({
  component: QRPage,
});

function QRPage() {
  const navigate = useNavigate();
  const [tab, setTab] = useState<"show" | "scan">("show");
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");

  useEffect(() => {
    supabase.auth.getUser().then(({ data: { user } }) => {
      if (!user) return;
      supabase.from("profiles").select("phone, full_name").eq("id", user.id).single().then(({ data }) => {
        if (data) {
          setPhone(data.phone);
          setName(data.full_name);
        }
      });
    });
  }, []);

  const [cameraError, setCameraError] = useState<string | null>(null);

  useEffect(() => {
    if (tab === "scan") {
      setCameraError(null);
      const scanner = new Html5QrcodeScanner("reader", { fps: 10, qrbox: { width: 250, height: 250 } }, false);
      scanner.render((decodedText) => {
        scanner.clear();
        navigate({ to: "/send", search: { to: decodedText } });
      }, (error) => {
        // Many non-critical errors pass through here (like no QR found in frame)
        // We only want to track critical failures like permission denied
        if (error?.includes("NotAllowedError") || error?.includes("Permission denied")) {
          setCameraError("Permiso de cámara denegado. Por favor, actívalo en tu navegador.");
        }
      });
      return () => {
        try {
          scanner.clear();
        } catch (e) {
          // console.error(e);
        }
      };
    }
  }, [tab, navigate]);

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <div className="flex items-center justify-between">
        <h1 className="font-display text-2xl font-bold text-foreground">Código QR</h1>
        <div className="flex gap-1 rounded-xl bg-accent p-1">
          <button
            onClick={() => setTab("show")}
            className={`flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-semibold transition ${
              tab === "show" ? "bg-background text-primary shadow-sm" : "text-muted-foreground"
            }`}
          >
            <QrCode className="h-3.5 w-3.5" /> Mi QR
          </button>
          <button
            onClick={() => setTab("scan")}
            className={`flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-semibold transition ${
              tab === "scan" ? "bg-background text-primary shadow-sm" : "text-muted-foreground"
            }`}
          >
            <Scan className="h-3.5 w-3.5" /> Escanear
          </button>
        </div>
      </div>

      <div className="mt-10">
        {tab === "show" ? (
          <div className="flex flex-col items-center">
            <div className="rounded-[2.5rem] border border-border bg-card p-10 shadow-[var(--shadow-card)]">
              {phone ? (
                <QRCodeSVG
                  value={phone}
                  size={200}
                  level="H"
                  includeMargin={false}
                  imageSettings={{
                    src: "/placeholder.svg",
                    height: 40,
                    width: 40,
                    excavate: true,
                  }}
                />
              ) : (
                <div className="grid h-[200px] w-[200px] place-items-center">
                  <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
                </div>
              )}
            </div>
            <div className="mt-8 text-center">
              <p className="font-display text-lg font-bold text-foreground">{name}</p>
              <p className="mt-1 text-sm text-muted-foreground">{phone}</p>
              <p className="mt-6 max-w-xs text-center text-xs leading-relaxed text-muted-foreground">
                Muestra este código a otro usuario para recibir dinero al instante.
              </p>
            </div>
          </div>
        ) : (
          <div className="flex flex-col items-center">
            <div id="reader" className="w-full overflow-hidden rounded-3xl border-2 border-dashed border-primary/30 bg-accent/30 min-h-[300px]"></div>
            {cameraError && (
              <div className="mt-4 p-4 rounded-xl bg-destructive/10 text-destructive text-xs font-semibold flex items-center gap-2">
                <X className="h-4 w-4" />
                {cameraError}
              </div>
            )}
            <p className="mt-6 text-center text-sm text-muted-foreground">
              Apunta la cámara al código QR del destinatario.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
