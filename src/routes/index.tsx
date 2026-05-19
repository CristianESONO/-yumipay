import { createFileRoute } from "@tanstack/react-router";
import { Link } from "@tanstack/react-router";
import { ArrowRight, Shield, Zap, Users } from "lucide-react";

export const Route = createFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <div className="min-h-screen bg-background">
      {/* Hero */}
      <section
        className="relative overflow-hidden text-primary-foreground"
        style={{ background: "var(--gradient-primary)" }}
      >
        <div className="absolute -top-32 -right-20 h-80 w-80 rounded-full bg-primary-glow/40 blur-3xl" />
        <div className="absolute -bottom-40 -left-20 h-80 w-80 rounded-full bg-primary-glow/30 blur-3xl" />

        <div className="relative mx-auto max-w-md px-6 pb-16 pt-10">
          <div className="flex items-center gap-2">
            <div className="grid h-9 w-9 place-items-center rounded-xl bg-white/10 backdrop-blur">
              <span className="font-display text-lg font-bold">Y</span>
            </div>
            <span className="font-display text-lg font-semibold tracking-tight">Yumi Pay</span>
          </div>

          <h1 className="mt-14 font-display text-5xl font-bold leading-[1.05]">
            Envía dinero<br />al instante en<br />Guinea Ecuatorial
          </h1>
          <p className="mt-5 max-w-sm text-base text-primary-foreground/75">
            La forma más rápida de transferir XAF entre personas. Sin filas, sin comisiones ocultas.
          </p>

          <div className="mt-8 flex flex-col gap-3">
            <Link
              to="/auth"
              className="group inline-flex h-14 items-center justify-center gap-2 rounded-2xl bg-white px-6 font-display text-base font-semibold text-primary shadow-[0_10px_40px_-10px_rgba(0,0,0,0.4)] transition active:scale-[0.98]"
            >
              Crear cuenta gratis
              <ArrowRight className="h-4 w-4 transition group-hover:translate-x-0.5" />
            </Link>
            <Link
              to="/auth"
              search={{ mode: "login" }}
              className="inline-flex h-14 items-center justify-center rounded-2xl border border-white/20 bg-white/5 px-6 font-display text-base font-medium text-primary-foreground backdrop-blur transition hover:bg-white/10"
            >
              Iniciar sesión
            </Link>
          </div>

          {/* Floating mock card */}
          <div className="mt-12 rounded-3xl border border-white/15 bg-white/10 p-5 backdrop-blur-xl">
            <p className="text-xs uppercase tracking-wider text-primary-foreground/60">Saldo disponible</p>
            <p className="mt-2 font-display text-3xl font-bold">450 000 XAF</p>
            <div className="mt-4 flex items-center justify-between text-sm">
              <span className="text-primary-foreground/70">→ María N.</span>
              <span className="font-semibold">−25 000 XAF</span>
            </div>
          </div>
        </div>
      </section>

      {/* Features */}
      <section className="mx-auto max-w-md px-6 py-14">
        <h2 className="font-display text-2xl font-bold text-foreground">Pensado para ti</h2>
        <div className="mt-6 space-y-3">
          {[
            { icon: Zap, title: "Transferencias al instante", desc: "El dinero llega en segundos a otro usuario Yumi." },
            { icon: Shield, title: "Seguro de extremo a extremo", desc: "Tus datos y saldo protegidos con cifrado bancario." },
            { icon: Users, title: "Solo necesitas un número", desc: "Envía a cualquier teléfono registrado en Yumi." },
          ].map(({ icon: Icon, title, desc }) => (
            <div key={title} className="flex gap-4 rounded-2xl border border-border bg-card p-4 shadow-[var(--shadow-soft)]">
              <div className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-accent text-primary">
                <Icon className="h-5 w-5" />
              </div>
              <div>
                <p className="font-display font-semibold text-foreground">{title}</p>
                <p className="mt-0.5 text-sm text-muted-foreground">{desc}</p>
              </div>
            </div>
          ))}
        </div>

        <p className="mt-10 text-center text-xs text-muted-foreground">
          Hecho en Malabo · XAF (Franco CFA)
        </p>
      </section>
    </div>
  );
}
