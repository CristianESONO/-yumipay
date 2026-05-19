import { createFileRoute, Outlet, Link, useNavigate, useLocation } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { Home, Send, Clock, User, ShieldCheck, QrCode, LayoutDashboard, Loader2 } from "lucide-react";

export const Route = createFileRoute("/_app")({
  component: AppLayout,
});

function AppLayout() {
  const navigate = useNavigate();
  const location = useLocation();
  const [ready, setReady] = useState(false);
  const [role, setRole] = useState<string | null>(null);

  useEffect(() => {
    const { data: sub } = supabase.auth.onAuthStateChange((_e, session) => {
      if (!session) navigate({ to: "/auth" });
    });
    
    async function init() {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session) {
        navigate({ to: "/auth" });
        return;
      }
      
      const { data: profile } = await supabase
        .from("profiles")
        .select("role")
        .eq("id", session.user.id)
        .single();
      
      // @ts-ignore
      setRole(profile?.role || "user");
      setReady(true);
    }

    init();
    return () => sub.subscription.unsubscribe();
  }, [navigate]);

  if (!ready) {
    return (
      <div className="grid min-h-screen place-items-center bg-background">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const tabs = [
    { to: "/home", icon: Home, label: "Inicio" },
    { to: "/send", icon: Send, label: "Enviar" },
    { to: "/qr", icon: QrCode, label: "QR" },
    ...(role === "admin" 
      ? [{ to: "/admin", icon: LayoutDashboard, label: "Admin" }] 
      : role === "agent" 
        ? [{ to: "/agent", icon: ShieldCheck, label: "Agente" }] 
        : []),
    { to: "/profile", icon: User, label: "Perfil" },
  ];

  const isAdminRoute = location.pathname === "/admin";

  if (isAdminRoute) {
    return <Outlet />;
  }

  return (
    <div className="min-h-screen bg-background pb-24">
      <Outlet />

      <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-card/95 backdrop-blur-xl">
        <div className="mx-auto flex max-w-md items-stretch justify-around px-2 pb-[max(env(safe-area-inset-bottom),0.5rem)] pt-2">
          {tabs.map((t) => {
            const active = location.pathname === t.to;
            const Icon = t.icon;
            return (
              <Link
                key={t.to}
                to={t.to}
                className={`flex flex-1 flex-col items-center gap-1 rounded-xl py-2 text-xs font-medium transition ${
                  active ? "text-primary" : "text-muted-foreground hover:text-foreground"
                }`}
              >
                <Icon className={`h-5 w-5 ${active ? "stroke-[2.4]" : ""}`} />
                {t.label}
              </Link>
            );
          })}
        </div>
      </nav>
    </div>
  );
}
