import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { User, Phone, Shield, LogOut, ChevronRight, Edit2, Check, X, Loader2, Trash2 } from "lucide-react";
import { toast } from "sonner";

export const Route = createFileRoute("/_app/profile")({
  component: ProfilePage,
});

function ProfilePage() {
  const navigate = useNavigate();
  const [profile, setProfile] = useState<any>(null);
  const [editing, setEditing] = useState(false);
  const [newName, setNewName] = useState("");
  const [loading, setLoading] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showSecurityModal, setShowSecurityModal] = useState(false);
  const [deleteReason, setDeleteReason] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [deleteLoading, setDeleteLoading] = useState(false);
  const [passwordLoading, setPasswordLoading] = useState(false);

  useEffect(() => {
    loadProfile();
  }, []);

  async function loadProfile() {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    const { data } = await supabase.from("profiles").select("*").eq("id", user.id).single();
    setProfile(data);
    setNewName(data.full_name);
  }

  async function handleLogout() {
    await supabase.auth.signOut();
    navigate({ to: "/" });
  }

  async function updateName() {
    if (!newName.trim()) return;
    setLoading(true);
    try {
      const { error } = await supabase.from("profiles").update({ full_name: newName.trim() }).eq("id", profile.id);
      if (error) throw error;
      setProfile({ ...profile, full_name: newName.trim() });
      setEditing(false);
      toast.success("Perfil actualizado");
    } catch (err: any) {
      toast.error(err.message);
    } finally {
      setLoading(false);
    }
  }

  async function requestAccountDeletion() {
    if (!deleteReason.trim()) return toast.error("Por favor, introduce el motivo de la baja");
    setDeleteLoading(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("request_account_deletion", { p_reason: deleteReason.trim() });
      if (error) throw error;
      toast.success("Solicitud de baja enviada");
      setShowDeleteModal(false);
      loadProfile();
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setDeleteLoading(false);
    }
  }

  async function handlePasswordChange() {
    if (newPassword.length < 6) return toast.error("La contraseña debe tener al menos 6 caracteres");
    setPasswordLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password: newPassword });
      if (error) throw error;
      toast.success("Contraseña actualizada correctamente");
      setShowSecurityModal(false);
      setNewPassword("");
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setPasswordLoading(false);
    }
  }

  if (!profile) return null;

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <h1 className="font-display text-2xl font-bold text-foreground">Perfil</h1>
      <p className="mt-1 text-sm text-muted-foreground">Gestiona tu información y seguridad.</p>

      <div className="mt-8 flex flex-col items-center">
        <div className="relative">
          <div className="grid h-24 w-24 place-items-center rounded-full bg-accent font-display text-3xl font-bold text-primary">
            {profile.full_name.charAt(0)}
          </div>
          <div className="absolute bottom-0 right-0 rounded-full border-4 border-background bg-success p-1.5 shadow-sm">
            <Shield className="h-3.5 w-3.5 text-white" />
          </div>
        </div>
        
        <div className="mt-4 text-center">
          {editing ? (
            <div className="flex items-center gap-2">
              <input
                className="input h-10 text-center"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                autoFocus
              />
              <button onClick={updateName} disabled={loading} className="rounded-lg bg-primary p-2 text-white">
                <Check className="h-4 w-4" />
              </button>
              <button onClick={() => { setEditing(false); setNewName(profile.full_name); }} className="rounded-lg bg-card p-2 text-muted-foreground">
                <X className="h-4 w-4" />
              </button>
            </div>
          ) : (
            <div className="flex items-center justify-center gap-2">
              <h2 className="font-display text-xl font-bold text-foreground">{profile.full_name}</h2>
              <button onClick={() => setEditing(true)} className="text-muted-foreground hover:text-primary">
                <Edit2 className="h-4 w-4" />
              </button>
            </div>
          )}
          <p className="text-sm font-medium text-muted-foreground">{profile.phone}</p>
          <div className="mt-2 inline-flex rounded-full bg-primary/10 px-3 py-1 text-xs font-semibold text-primary uppercase tracking-wider">
            {profile.role}
          </div>
        </div>
      </div>

      <div className="mt-10 space-y-3">
        {profile.role === "user" && (
          <div className="rounded-2xl border border-primary/20 bg-primary/5 p-5">
            <h3 className="font-display text-sm font-bold text-primary">¿Quieres ser Agente?</h3>
            <p className="mt-1 text-xs text-muted-foreground leading-relaxed">
              Como agente de CCEI Bank, podrás realizar recargas y retiros para otros clientes y ganar comisiones.
            </p>
            {(!profile.agent_status || profile.agent_status === "none" || profile.agent_status === "rejected") ? (
              <button
                onClick={async () => {
                  setLoading(true);
                  try {
                    // @ts-ignore
                    const { error } = await supabase.rpc("request_agent_role");
                    if (error) throw error;
                    toast.success("Solicitud enviada");
                    loadProfile();
                  } catch (e: any) {
                    toast.error(e.message);
                  } finally {
                    setLoading(false);
                  }
                }}
                disabled={loading}
                className="mt-4 inline-flex h-10 w-full items-center justify-center rounded-xl bg-primary text-xs font-bold text-primary-foreground shadow-sm transition active:scale-[0.98] disabled:opacity-50"
              >
                Solicitar cuenta de Agente
              </button>
            ) : profile.agent_status === "pending" ? (
              <div className="mt-4 flex items-center gap-2 rounded-xl border border-warning/30 bg-warning/10 p-3 text-xs font-medium text-warning-foreground">
                <Loader2 className="h-4 w-4 animate-spin" />
                Solicitud en revisión por el banco...
              </div>
            ) : null}
          </div>
        )}

        <div className="rounded-2xl border border-border bg-card p-1">
          <button 
            onClick={() => setShowSecurityModal(true)}
            className="flex w-full items-center justify-between rounded-xl px-4 py-3.5 text-sm font-medium text-foreground transition hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-primary">
                <Shield className="h-4 w-4" />
              </div>
              Seguridad y PIN
            </div>
            <ChevronRight className="h-4 w-4 text-muted-foreground" />
          </button>
          <button 
            onClick={() => toast.info("Tu identidad está verificada (Nivel 2)")}
            className="flex w-full items-center justify-between rounded-xl px-4 py-3.5 text-sm font-medium text-foreground transition hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-primary">
                <User className="h-4 w-4" />
              </div>
              Verificación de identidad
            </div>
            <div className="flex items-center gap-1.5">
              <span className="text-[10px] font-bold text-success uppercase tracking-widest">Nivel 2</span>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
          </button>
        </div>

        {!profile.deletion_requested ? (
          <button
            onClick={() => setShowDeleteModal(true)}
            className="flex w-full items-center gap-3 rounded-2xl border border-slate-200 bg-white px-5 py-4 text-sm font-semibold text-slate-500 transition hover:bg-destructive/5 hover:text-destructive hover:border-destructive/20"
          >
            <Trash2 className="h-5 w-5" />
            Solicitar borrar cuenta
          </button>
        ) : (
          <div className="rounded-2xl border border-destructive/20 bg-destructive/5 p-4 text-center">
            <p className="text-xs font-bold text-destructive uppercase tracking-widest mb-1">Baja solicitada</p>
            <p className="text-[10px] text-muted-foreground">Tu solicitud está siendo procesada por el administrador.</p>
          </div>
        )}

        <button
          onClick={handleLogout}
          className="flex w-full items-center gap-3 rounded-2xl border border-destructive/20 bg-destructive/5 px-5 py-4 text-sm font-semibold text-destructive transition hover:bg-destructive/10"
        >
          <LogOut className="h-5 w-5" />
          Cerrar sesión
        </button>
      </div>
      
      <div className="mt-10 text-center space-y-1">
        <p className="text-[10px] text-muted-foreground uppercase tracking-[0.2em] font-bold opacity-50">
          Yumi Pay Version 1.0.5
        </p>
        <p className="text-[10px] text-slate-400 font-medium">
          Developed by <span className="text-primary/70 font-bold">Ruslan Cristian ESONO MAYE</span>
        </p>
        <p className="text-[9px] text-slate-300 font-bold tracking-widest">INNOTECHGE</p>
      </div>

      {showDeleteModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-[2rem] bg-white p-8 shadow-2xl animate-in fade-in zoom-in duration-300">
            <h3 className="font-display text-xl font-bold text-slate-800">Borrar cuenta</h3>
            <p className="mt-2 text-sm text-slate-500 leading-relaxed">
              Lamentamos que te vayas. Cuéntanos por qué quieres cerrar tu cuenta:
            </p>
            <textarea
              className="mt-6 w-full rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm focus:ring-2 focus:ring-primary/20 outline-none transition-all h-32 resize-none"
              placeholder="Escribe tu motivo aquí..."
              value={deleteReason}
              onChange={(e) => setDeleteReason(e.target.value)}
            />
            <div className="mt-8 flex flex-col gap-3">
              <button
                onClick={requestAccountDeletion}
                disabled={deleteLoading}
                className="flex h-12 w-full items-center justify-center rounded-xl bg-destructive text-sm font-bold text-white shadow-lg active:scale-95 transition-transform disabled:opacity-50"
              >
                {deleteLoading ? <Loader2 className="h-5 w-5 animate-spin" /> : "Confirmar solicitud de baja"}
              </button>
              <button
                onClick={() => setShowDeleteModal(false)}
                className="h-12 w-full text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors"
              >
                Cancelar
              </button>
            </div>
          </div>
        </div>
      )}

      {showSecurityModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-[2rem] bg-white p-8 shadow-2xl animate-in fade-in zoom-in duration-300">
            <h3 className="font-display text-xl font-bold text-slate-800">Seguridad y PIN</h3>
            <p className="mt-2 text-sm text-slate-500 leading-relaxed">
              Actualiza tu contraseña de acceso a Yumi Pay. Esta será tu clave para entrar y autorizar operaciones.
            </p>
            <div className="mt-6 space-y-4">
              <div>
                <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest ml-1">Nueva Contraseña</label>
                <input
                  type="password"
                  className="mt-1 w-full h-12 rounded-xl border border-slate-200 bg-slate-50 px-4 text-sm focus:ring-2 focus:ring-primary/20 outline-none transition-all"
                  placeholder="Mínimo 6 caracteres"
                  value={newPassword}
                  onChange={(e) => setNewPassword(e.target.value)}
                />
              </div>
            </div>
            <div className="mt-8 flex flex-col gap-3">
              <button
                onClick={handlePasswordChange}
                disabled={passwordLoading}
                className="flex h-12 w-full items-center justify-center rounded-xl bg-primary text-sm font-bold text-white shadow-lg active:scale-95 transition-transform disabled:opacity-50"
              >
                {passwordLoading ? <Loader2 className="h-5 w-5 animate-spin" /> : "Guardar cambios"}
              </button>
              <button
                onClick={() => setShowSecurityModal(false)}
                className="h-12 w-full text-sm font-bold text-slate-400 hover:text-slate-600 transition-colors"
              >
                Cancelar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
