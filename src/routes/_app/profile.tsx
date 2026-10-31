import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { 
  User, 
  Shield, 
  LogOut, 
  ChevronRight, 
  Edit2, 
  Check, 
  X, 
  Loader2, 
  Trash2, 
  KeyRound, 
  FileCheck2, 
  AlertCircle,
  Lock
} from "lucide-react";
import { toast } from "sonner";
import { PinModal } from "@/components/PinModal";

export const Route = createFileRoute("/_app/profile")({
  component: ProfilePage,
});

export function ProfilePage() {
  const navigate = useNavigate();
  const [profile, setProfile] = useState<any>(null);
  const [editing, setEditing] = useState(false);
  const [newName, setNewName] = useState("");
  const [loading, setLoading] = useState(false);

  // Modals state
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showSecurityModal, setShowSecurityModal] = useState(false);
  const [showPinSetupModal, setShowPinSetupModal] = useState(false);
  const [pinOld, setPinOld] = useState<string | null>(null);
  const [showKycModal, setShowKycModal] = useState(false);

  // Form states
  const [deleteReason, setDeleteReason] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [deleteLoading, setDeleteLoading] = useState(false);
  const [passwordLoading, setPasswordLoading] = useState(false);
  const [pinLoading, setPinLoading] = useState(false);

  // KYC state
  const [docType, setDocType] = useState<"DIP" | "passport" | "residence_card">("DIP");
  const [docNumber, setDocNumber] = useState("");
  const [kycLoading, setKycLoading] = useState(false);
  const [myKyc, setMyKyc] = useState<any>(null);

  useEffect(() => {
    loadProfile();
  }, []);

  async function loadProfile() {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    const { data, error } = await supabase.from("profiles").select("*").eq("id", user.id).maybeSingle();
    
    if (error || !data) {
      console.error("Error al cargar perfil:", error);
      toast.error("Tu sesión ha expirado o el perfil ha sido eliminado.");
      await supabase.auth.signOut();
      navigate({ to: "/auth" });
      return;
    }

    setProfile(data);
    setNewName(data.full_name);

    // Charger état KYC
    const { data: kycData } = await supabase
      .from("kyc_verifications" as any)
      .select("*")
      .eq("user_id", user.id)
      .order("submitted_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    setMyKyc(kycData);
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

  async function handlePinSetup(pin: string) {
    const needsOld = Boolean(profile?.pin_set);
    if (needsOld && !pinOld) {
      setPinOld(pin);
      return;
    }
    setPinLoading(true);
    try {
      // @ts-ignore
      const { data, error } = await supabase.rpc("set_transaction_pin", {
        p_new_pin: pin,
        p_old_pin: pinOld ?? undefined,
      });
      if (error) throw error;
      if (data && (data as { ok?: boolean }).ok === false) {
        throw new Error((data as { message?: string }).message || "Error al configurar PIN");
      }
      toast.success("Código PIN de 4 dígitos configurado con éxito");
      setShowPinSetupModal(false);
      setPinOld(null);
      loadProfile();
    } catch (e: any) {
      toast.error(e.message || "Error al configurar PIN");
      setPinOld(null);
    } finally {
      setPinLoading(false);
    }
  }

  async function handleSubmitKyc(e: React.FormEvent) {
    e.preventDefault();
    if (!docNumber.trim()) return toast.error("Introduce el número de tu documento");
    setKycLoading(true);
    try {
      // @ts-ignore
      const { error } = await supabase.rpc("submit_kyc", {
        p_doc_type: docType,
        p_doc_number: docNumber.trim(),
      });
      if (error) throw error;
      toast.success("Expediente KYC enviado para revisión bancaria");
      setShowKycModal(false);
      loadProfile();
    } catch (e: any) {
      toast.error(e.message || "Error al enviar documento KYC");
    } finally {
      setKycLoading(false);
    }
  }

  if (!profile) return null;

  const currentTier = profile.kyc_tier || "tier_1";

  return (
    <div className="mx-auto max-w-md px-5 pb-8 pt-6">
      <h1 className="font-display text-2xl font-bold text-foreground">Perfil</h1>
      <p className="mt-1 text-sm text-muted-foreground">Gestiona tu información, límites y seguridad bancaria.</p>

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
          <div className="mt-2 inline-flex items-center gap-2">
            <span className="rounded-full bg-primary/10 px-3 py-1 text-xs font-semibold text-primary uppercase tracking-wider">
              {profile.role}
            </span>
            <span className="rounded-full bg-accent px-3 py-1 text-xs font-bold text-foreground uppercase tracking-wider">
              {currentTier === "tier_2" ? "KYC Nivel 2" : currentTier === "tier_3" ? "KYC Pro" : "KYC Básico"}
            </span>
          </div>
        </div>
      </div>

      <div className="mt-8 space-y-3">
        {/* Agent request banner */}
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

        {/* Security & KYC Options */}
        <div className="rounded-2xl border border-border bg-card p-1">
          {/* PIN Option */}
          <button 
            onClick={() => setShowPinSetupModal(true)}
            className="flex w-full items-center justify-between rounded-xl px-4 py-3.5 text-sm font-medium text-foreground transition hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-primary">
                <KeyRound className="h-4 w-4" />
              </div>
              <div className="text-left">
                <p className="text-sm font-semibold">Código PIN de Transacción</p>
                <p className="text-[10px] text-muted-foreground">Protege tus envíos y retiros de efectivo</p>
              </div>
            </div>
            <div className="flex items-center gap-1.5">
              <span className="text-[10px] font-bold text-success uppercase tracking-widest">
                {profile.pin_set ? "Configurado" : "Definir"}
              </span>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
          </button>

          {/* KYC Option */}
          <button 
            onClick={() => setShowKycModal(true)}
            className="flex w-full items-center justify-between rounded-xl px-4 py-3.5 text-sm font-medium text-foreground transition hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-primary">
                <FileCheck2 className="h-4 w-4" />
              </div>
              <div className="text-left">
                <p className="text-sm font-semibold">Identidad y Límites (KYC BEAC)</p>
                <p className="text-[10px] text-muted-foreground">
                  {currentTier === "tier_1" ? "Límite: 200.000 XAF/día" : "Límite: 2.000.000 XAF/día"}
                </p>
              </div>
            </div>
            <div className="flex items-center gap-1.5">
              <span className={`text-[10px] font-bold uppercase tracking-widest ${
                currentTier === "tier_2" || currentTier === "tier_3" ? "text-success" : "text-primary"
              }`}>
                {currentTier === "tier_2" ? "Nivel 2" : currentTier === "tier_3" ? "Pro" : "Subir Nivel"}
              </span>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </div>
          </button>

          {/* Password Option */}
          <button 
            onClick={() => setShowSecurityModal(true)}
            className="flex w-full items-center justify-between rounded-xl px-4 py-3.5 text-sm font-medium text-foreground transition hover:bg-accent/50"
          >
            <div className="flex items-center gap-3">
              <div className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-primary">
                <Lock className="h-4 w-4" />
              </div>
              <div className="text-left">
                <p className="text-sm font-semibold">Contraseña de acceso</p>
                <p className="text-[10px] text-muted-foreground">Cambiar clave de inicio de sesión</p>
              </div>
            </div>
            <ChevronRight className="h-4 w-4 text-muted-foreground" />
          </button>
        </div>

        {/* Delete account */}
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
          Yumi Pay Version 2.0 (Banking Standard)
        </p>
        <p className="text-[10px] text-slate-400 font-medium">
          Desarrollado por <span className="text-primary/70 font-bold">Ruslan Cristian ESONO MAYE</span>
        </p>
        <p className="text-[9px] text-slate-300 font-bold tracking-widest">INNOTECHGE</p>
      </div>

      {/* PIN Setup Modal */}
      <PinModal
        isOpen={showPinSetupModal}
        onClose={() => {
          setShowPinSetupModal(false);
          setPinOld(null);
        }}
        onSuccess={handlePinSetup}
        title={profile.pin_set && !pinOld ? "PIN actual" : "Configura tu PIN de 4 dígitos"}
        description={
          profile.pin_set && !pinOld
            ? "Introduce tu PIN actual para poder cambiarlo."
            : "Este código secreto será requerido para confirmar cada envío o retiro de dinero."
        }
      />

      {/* KYC Verification Modal */}
      {showKycModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-[2rem] bg-white p-7 shadow-2xl animate-in fade-in zoom-in duration-300">
            <div className="flex items-center justify-between">
              <h3 className="font-display text-xl font-bold text-slate-800">Verificación de Identidad</h3>
              <button onClick={() => setShowKycModal(false)} className="rounded-full bg-slate-100 p-1.5 text-slate-500">
                <X className="h-4 w-4" />
              </button>
            </div>
            
            <p className="mt-2 text-xs text-slate-500 leading-relaxed">
              Conforme a la normativa BEAC/COBAC, verificar tu documento oficial eleva tu límite diario de 200.000 XAF a <strong>2.000.000 XAF</strong>.
            </p>

            {myKyc?.status === "pending" ? (
              <div className="mt-6 rounded-2xl border border-warning/30 bg-warning/10 p-4 text-xs space-y-1">
                <p className="font-bold text-warning-foreground">Expediente en verificación</p>
                <p className="text-slate-600">Documento: {myKyc.doc_type} • Nº {myKyc.doc_number}</p>
                <p className="text-[10px] text-slate-400">El equipo de cumplimiento bancario está validando tus datos.</p>
              </div>
            ) : (
              <form onSubmit={handleSubmitKyc} className="mt-6 space-y-4">
                <div>
                  <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Tipo de Documento</label>
                  <select
                    value={docType}
                    onChange={(e: any) => setDocType(e.target.value)}
                    className="mt-1 w-full h-11 rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm font-medium text-slate-800 outline-none"
                  >
                    <option value="DIP">DIP (Documento Nacional de Identidad)</option>
                    <option value="passport">Pasaporte Oficial</option>
                    <option value="residence_card">Tarjeta de Residencia</option>
                  </select>
                </div>

                <div>
                  <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Número de Documento</label>
                  <input
                    required
                    type="text"
                    value={docNumber}
                    onChange={(e) => setDocNumber(e.target.value)}
                    placeholder="Ej. DIP-0019283-GE"
                    className="mt-1 w-full h-11 rounded-xl border border-slate-200 bg-slate-50 px-3 text-sm font-medium text-slate-800 outline-none"
                  />
                </div>

                <div className="pt-2 flex flex-col gap-2">
                  <button
                    type="submit"
                    disabled={kycLoading}
                    className="flex h-11 w-full items-center justify-center rounded-xl bg-primary text-sm font-bold text-white shadow-md active:scale-95 transition-transform disabled:opacity-50"
                  >
                    {kycLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : "Enviar Documento a Revisión"}
                  </button>
                  <button
                    type="button"
                    onClick={() => setShowKycModal(false)}
                    className="h-9 w-full text-xs font-semibold text-slate-400 hover:text-slate-600"
                  >
                    Cerrar
                  </button>
                </div>
              </form>
            )}
          </div>
        </div>
      )}

      {/* Account Deletion Modal */}
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

      {/* Password Change Modal */}
      {showSecurityModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-5 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-[2rem] bg-white p-8 shadow-2xl animate-in fade-in zoom-in duration-300">
            <h3 className="font-display text-xl font-bold text-slate-800">Contraseña de acceso</h3>
            <p className="mt-2 text-sm text-slate-500 leading-relaxed">
              Actualiza tu contraseña de acceso a Yumi Pay.
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
