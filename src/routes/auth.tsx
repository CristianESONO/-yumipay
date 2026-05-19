import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { ArrowLeft, Loader2 } from "lucide-react";
import { toast } from "sonner";

type SearchParams = { mode?: "signup" | "login" };

export const Route = createFileRoute("/auth")({
  validateSearch: (s: Record<string, unknown>): SearchParams => ({
    mode: s.mode === "login" ? "login" : "signup",
  }),
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const { mode: initialMode } = Route.useSearch();
  const [mode, setMode] = useState<"signup" | "login">(initialMode ?? "signup");
  const [role, setRole] = useState<"user" | "agent">("user");
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleRedirect(userId: string) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", userId)
      .single();
    
    // @ts-ignore
    const role = profile?.role || "user";
    if (role === "admin") {
      navigate({ to: "/admin" as any });
    } else if (role === "agent") {
      navigate({ to: "/agent" as any });
    } else {
      navigate({ to: "/home" as any });
    }
  }

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) handleRedirect(data.session.user.id);
    });
  }, [navigate]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      if (mode === "signup") {
        const { data, error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            emailRedirectTo: window.location.origin + "/home",
            data: { full_name: fullName, phone, role },
          },
        });
        if (error) throw error;
        toast.success(role === 'agent' ? "¡Cuenta de Agente creada!" : "¡Cuenta creada! Bienvenido a Yumi.");
        if (data.user) handleRedirect(data.user.id);
      } else {
        const { data, error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        toast.success("Sesión iniciada");
        if (data.user) handleRedirect(data.user.id);
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error";
      toast.error(msg);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen bg-background pb-12">
      <div className="mx-auto max-w-md px-6 pt-6">
        <Link to="/" className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
          <ArrowLeft className="h-4 w-4" /> Atrás
        </Link>

        <div className="mt-8">
          <h1 className="font-display text-3xl font-bold text-foreground">
            {mode === "signup" ? "Crear tu cuenta" : "Bienvenido de vuelta"}
          </h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {mode === "signup"
              ? role === 'agent' 
                ? "Empieza a gestionar recargas y ganar comisiones hoy mismo."
                : "Comienza con 50 000 XAF de bono de bienvenida."
              : "Inicia sesión para gestionar tu dinero."}
          </p>
        </div>

        {mode === "signup" && (
          <div className="mt-6 flex gap-1 rounded-2xl bg-accent/50 p-1">
            <button
              type="button"
              onClick={() => setRole("user")}
              className={`flex-1 py-3 rounded-xl text-xs font-bold uppercase transition ${role === 'user' ? 'bg-background text-primary shadow-sm' : 'text-muted-foreground'}`}
            >
              Cliente
            </button>
            <button
              type="button"
              onClick={() => setRole("agent")}
              className={`flex-1 py-3 rounded-xl text-xs font-bold uppercase transition ${role === 'agent' ? 'bg-background text-primary shadow-sm' : 'text-muted-foreground'}`}
            >
              Agente
            </button>
          </div>
        )}

        <form onSubmit={onSubmit} className="mt-8 space-y-4">
          {mode === "signup" && (
            <>
              <Field label="Nombre completo">
                <input
                  required
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  className="input"
                  placeholder="Ej. Ana Mba"
                />
              </Field>
              <Field label="Teléfono">
                <input
                  required
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  className="input"
                  placeholder="+240 222 000 000"
                  inputMode="tel"
                />
              </Field>
            </>
          )}
          <Field label="Correo electrónico">
            <input
              required
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="input"
              placeholder="tu@correo.com"
            />
          </Field>
          <Field label="Contraseña">
            <input
              required
              type="password"
              minLength={6}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="input"
              placeholder="Mínimo 6 caracteres"
            />
          </Field>

          <button
            type="submit"
            disabled={loading}
            className="mt-2 inline-flex h-14 w-full items-center justify-center gap-2 rounded-2xl bg-primary font-display text-base font-semibold text-primary-foreground shadow-[var(--shadow-card)] transition active:scale-[0.98] disabled:opacity-60"
          >
            {loading && <Loader2 className="h-4 w-4 animate-spin" />}
            {mode === "signup" ? (role === 'agent' ? 'Abrir Punto Yumi' : 'Crear cuenta') : "Iniciar sesión"}
          </button>
        </form>

        <p className="mt-6 text-center text-sm text-muted-foreground">
          {mode === "signup" ? "¿Ya tienes cuenta?" : "¿Aún no tienes cuenta?"}{" "}
          <button
            type="button"
            onClick={() => setMode(mode === "signup" ? "login" : "signup")}
            className="font-semibold text-primary hover:underline"
          >
            {mode === "signup" ? "Inicia sesión" : "Regístrate"}
          </button>
        </p>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-sm font-medium text-foreground">{label}</span>
      {children}
    </label>
  );
}
