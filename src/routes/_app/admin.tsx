import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { 
  Users, 
  CheckCircle, 
  XCircle, 
  BarChart3, 
  Clock, 
  Loader2, 
  ShieldCheck, 
  History, 
  AlertTriangle,
  RotateCcw,
  LayoutDashboard,
  TrendingUp,
  Search,
  Download,
  Filter,
  UserPlus,
  LogOut
} from "lucide-react";
import { toast } from "sonner";
import { formatXAF } from "@/lib/format";

export const Route = createFileRoute("/_app/admin")({
  component: AdminPage,
});

function AdminPage() {
  const navigate = useNavigate();
  const [activeTab, setActiveTab] = useState<'overview' | 'requests' | 'audit' | 'reversals'>('overview');
  const [auditFilter, setAuditFilter] = useState<'all' | 'p2p' | 'deposit' | 'system'>('all');
  const [requests, setRequests] = useState<any[]>([]);
  const [auditLog, setAuditLog] = useState<any[]>([]);
  const [reversals, setReversals] = useState<any[]>([]);
  const [stats, setStats] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadData();
  }, [activeTab, auditFilter]);

  async function loadData() {
    setLoading(true);
    try {
      const { data: profiles } = await supabase.from("profiles").select("balance_xaf, role, agent_balance_xaf");
      const totalBalance = profiles?.reduce((sum: number, p: any) => sum + Number(p.balance_xaf) + Number(p.agent_balance_xaf || 0), 0) || 0;
      setStats({ 
        totalBalance, 
        totalUsers: profiles?.length || 0, 
        totalAgents: profiles?.filter((p: any) => p.role === 'agent').length || 0,
        pendingAgents: 0 
      });

      if (activeTab === 'overview' || activeTab === 'requests') {
        const { data } = await supabase
          .from("agent_requests")
          .select("*, user:profiles!agent_requests_user_id_fkey(full_name, phone)")
          .eq("status", "pending")
          .order("created_at", { ascending: false });
        setRequests(data || []);
        if (stats) setStats((prev: any) => ({ ...prev, pendingAgents: data?.length || 0 }));
      }

      if (activeTab === 'audit') {
        let query = supabase
          .from("transactions")
          .select("*, sender:profiles!transactions_sender_id_fkey(full_name, phone), recipient:profiles!transactions_recipient_id_fkey(full_name, phone)")
          .order("created_at", { ascending: false })
          .limit(50);
        
        if (auditFilter !== 'all') {
          query = query.eq("type", auditFilter);
        }
        const { data } = await query;
        setAuditLog(data || []);
      }

      if (activeTab === 'reversals') {
        const { data } = await supabase
          .from("transactions")
          .select("*, sender:profiles!transactions_sender_id_fkey(full_name, phone), recipient:profiles!transactions_recipient_id_fkey(full_name, phone)")
          .eq("status", "reversal_pending")
          .order("reversal_requested_at", { ascending: false });
        setReversals(data || []);
      }
    } catch (e: any) {
      toast.error(e.message);
    } finally {
      setLoading(false);
    }
  }

  async function processAction(rpc: string, args: any, successMsg: string) {
    try {
      const { error } = await supabase.rpc(rpc, args);
      if (error) throw error;
      toast.success(successMsg);
      loadData();
    } catch (e: any) {
      toast.error(e.message);
    }
  }

  async function handleLogout() {
    await supabase.auth.signOut();
    navigate({ to: "/auth" });
    toast.success("Sesión cerrada correctamente");
  }

  return (
    <div className="flex min-h-screen bg-[#F8FAFC]">
      <aside className="hidden lg:flex w-64 flex-col border-r border-slate-200 bg-white shadow-sm transition-all duration-300 overflow-hidden">
        <div className="p-6">
          <div className="flex items-center gap-2">
            <div className="h-8 w-8 rounded-lg bg-primary grid place-items-center text-white font-bold">Y</div>
            <span className="font-display text-xl font-bold text-slate-800">Yumi Bank</span>
          </div>
        </div>
        
        <nav className="flex-1 px-4 space-y-1 mt-4">
          <SidebarLink active={activeTab === 'overview'} onClick={() => setActiveTab('overview')} icon={<LayoutDashboard size={20}/>} label="Panel General" />
          <SidebarLink active={activeTab === 'requests'} onClick={() => setActiveTab('requests')} icon={<UserPlus size={20}/>} label="Solicitudes" count={requests.length} />
          <SidebarLink active={activeTab === 'audit'} onClick={() => setActiveTab('audit')} icon={<History size={20}/>} label="Auditoría Global" />
          <SidebarLink active={activeTab === 'reversals'} onClick={() => setActiveTab('reversals')} icon={<AlertTriangle size={20}/>} label="Reclamaciones" count={reversals.length} />
        </nav>

        <div className="p-4 mt-auto border-t border-slate-100 space-y-2">
          <div className="flex items-center gap-3 p-2 rounded-xl bg-slate-50">
            <div className="h-9 w-9 rounded-full bg-primary/10 text-primary grid place-items-center font-bold text-sm">AD</div>
            <div className="overflow-hidden">
              <p className="text-xs font-bold text-slate-800 truncate">Soporte Banco</p>
              <p className="text-[10px] text-slate-500 truncate">admin@yumipay.com</p>
            </div>
          </div>
          <button 
            onClick={handleLogout}
            className="w-full flex items-center gap-3 px-4 py-2 text-sm font-semibold text-slate-600 hover:text-destructive hover:bg-destructive/5 rounded-xl transition-colors"
          >
            <LogOut size={18} />
            <span>Desconectarse</span>
          </button>
        </div>
      </aside>

      <main className="flex-1 flex flex-col min-w-0">
        <header className="h-16 border-b border-slate-200 bg-white/80 backdrop-blur-md flex items-center justify-between px-8 sticky top-0 z-30">
          <h2 className="text-sm font-bold text-slate-600 uppercase tracking-tight">
            {activeTab === 'overview' && "Resumen Ejecutivo"}
            {activeTab === 'requests' && "Gestión de Agentes"}
            {activeTab === 'audit' && "Auditoría de Transacciones"}
            {activeTab === 'reversals' && "Resolución de Disputas"}
          </h2>
          <div className="flex items-center gap-4">
            <div className="relative group">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 group-focus-within:text-primary transition-colors" size={16}/>
              <input type="text" placeholder="Buscar transacción..." className="bg-slate-100 border-none rounded-full pl-10 pr-4 py-2 text-xs w-64 focus:ring-2 focus:ring-primary/20 transition-all outline-none" />
            </div>
            <button className="h-9 w-9 grid place-items-center rounded-lg bg-slate-100 text-slate-600 hover:bg-slate-200 transition-colors"><Download size={18}/></button>
          </div>
        </header>

        <div className="p-8 overflow-y-auto h-[calc(100vh-64px)] scroll-smooth">
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
            <StatCard label="Circulante Total" value={formatXAF(stats?.totalBalance || 0)} trend="+2.4%" icon={<TrendingUp className="text-emerald-500" size={20}/>} />
            <StatCard label="Usuarios Totales" value={stats?.totalUsers || 0} icon={<Users className="text-indigo-500" size={20}/>} />
            <StatCard label="Agentes Activos" value={stats?.totalAgents || 0} icon={<ShieldCheck className="text-primary" size={20}/>} />
            <StatCard label="Tareas Pendientes" value={requests.length + reversals.length} icon={<Clock className="text-amber-500" size={20}/>} color="bg-amber-50" />
          </div>

          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
            {activeTab === 'overview' && (
              <div className="p-6">
                <div className="flex items-center justify-between mb-6">
                  <h3 className="font-display font-bold text-slate-800">Actividad Crítica Requerida</h3>
                  <button className="text-xs font-bold text-primary hover:underline">Ver todo</button>
                </div>
                <div className="space-y-4">
                  {requests.length === 0 && reversals.length === 0 ? (
                    <div className="text-center py-12 text-slate-400 italic">No hay tareas pendientes de alta prioridad.</div>
                  ) : (
                    <>
                      {requests.map(req => <CompactRequestRow key={req.id} req={req} onAction={processAction} />)}
                      {reversals.map(rev => <CompactReversalRow key={rev.id} rev={rev} onAction={processAction} />)}
                    </>
                  )}
                </div>
              </div>
            )}

            {activeTab === 'audit' && (
              <div className="overflow-x-auto">
                <table className="w-full text-left border-collapse">
                  <thead>
                    <tr className="border-b border-slate-100 bg-slate-50/50">
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Remitente</th>
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Destinatario</th>
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Tipo</th>
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest text-right">Monto</th>
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Estado</th>
                      <th className="px-6 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Fecha</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-50">
                    {auditLog.map(tx => (
                      <tr key={tx.id} className="hover:bg-slate-50/80 transition-colors group">
                        <td className="px-6 py-4">
                          <div className="flex items-center gap-3">
                            <div className="h-8 w-8 rounded-full bg-slate-200 text-[10px] font-bold grid place-items-center">{tx.sender?.full_name?.charAt(0)}</div>
                            <div className="overflow-hidden">
                              <p className="text-xs font-bold text-slate-700 truncate">{tx.sender?.full_name}</p>
                              <p className="text-[10px] text-slate-400">{tx.sender?.phone}</p>
                            </div>
                          </div>
                        </td>
                        <td className="px-6 py-4">
                          <p className="text-xs font-semibold text-slate-600">{tx.recipient?.full_name}</p>
                        </td>
                        <td className="px-6 py-4">
                          <span className={`text-[10px] font-bold px-2 py-1 rounded-full ${tx.type === 'transfer' ? 'bg-indigo-50 text-indigo-600' : 'bg-emerald-50 text-emerald-600'}`}>
                            {tx.type.toUpperCase()}
                          </span>
                        </td>
                        <td className="px-6 py-4 text-right">
                          <p className="text-xs font-black text-slate-800">{formatXAF(tx.amount_xaf)}</p>
                        </td>
                        <td className="px-6 py-4">
                          <div className="flex items-center gap-1.5 font-bold text-[10px] text-slate-500 uppercase">
                            <div className={`h-1.5 w-1.5 rounded-full ${tx.status === 'completed' ? 'bg-emerald-500' : 'bg-slate-300'}`} />
                            {tx.status}
                          </div>
                        </td>
                        <td className="px-6 py-4 text-[10px] text-slate-400 font-medium">
                          {new Date(tx.created_at).toLocaleString()}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

function SidebarLink({ active, onClick, icon, label, count }: any) {
  return (
    <button
      onClick={onClick}
      className={`w-full flex items-center justify-between px-4 py-2.5 rounded-xl transition-all duration-200 ${
        active 
          ? 'bg-primary text-white shadow-lg shadow-primary/20' 
          : 'text-slate-500 hover:bg-slate-50 hover:text-slate-800'
      }`}
    >
      <div className="flex items-center gap-3">
        {icon}
        <span className="text-sm font-semibold">{label}</span>
      </div>
      {count !== undefined && count > 0 && (
        <span className={`text-[10px] font-bold px-2 py-0.5 rounded-full ${active ? 'bg-white/20 text-white' : 'bg-primary/10 text-primary'}`}>
          {count}
        </span>
      )}
    </button>
  );
}

function StatCard({ label, value, trend, icon, color = "bg-white" }: any) {
  return (
    <div className={`${color} p-6 rounded-2xl border border-slate-200 shadow-sm transition-transform hover:-translate-y-1 duration-300`}>
      <div className="flex justify-between items-start mb-4">
        <div className="h-10 w-10 rounded-xl bg-slate-50 grid place-items-center border border-slate-100 shadow-inner">
          {icon}
        </div>
        {trend && (
          <span className="text-[10px] font-bold text-emerald-600 bg-emerald-50 px-2 py-1 rounded-full">{trend}</span>
        )}
      </div>
      <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">{label}</p>
      <p className="text-2xl font-display font-black text-slate-800 mt-1">{value}</p>
    </div>
  );
}

function CompactRequestRow({ req, onAction }: any) {
  return (
    <div className="flex items-center justify-between p-4 bg-slate-50/50 rounded-xl border border-slate-100 transition-hover hover:border-primary/20 hover:bg-white group">
      <div className="flex items-center gap-4">
        <div className="h-10 w-10 rounded-full bg-white border border-slate-200 flex items-center justify-center font-bold text-primary shadow-sm">
          {req.user?.full_name?.charAt(0)}
        </div>
        <div>
          <p className="text-sm font-bold text-slate-700">Solicitud de Agente: {req.user?.full_name}</p>
          <p className="text-xs text-slate-400">Telf: {req.user?.phone} • {new Date(req.created_at).toLocaleDateString()}</p>
        </div>
      </div>
      <div className="flex gap-2">
        <button 
          onClick={() => onAction("process_agent_request", { p_request_id: req.id, p_approve: true, p_note: "Aprobado" }, "Agente aprobado")}
          className="h-8 px-4 rounded-lg bg-primary text-white text-[10px] font-bold hover:bg-primary/90 transition-colors"
        >
          Aprobar
        </button>
        <button 
          onClick={() => onAction("process_agent_request", { p_request_id: req.id, p_approve: false, p_note: "Denegado" }, "Solicitud rechazada")}
          className="h-8 px-4 rounded-lg bg-slate-200 text-slate-600 text-[10px] font-bold hover:bg-slate-300 transition-colors"
        >
          Rechazar
        </button>
      </div>
    </div>
  );
}

function CompactReversalRow({ rev, onAction }: any) {
  return (
    <div className="flex items-center justify-between p-4 bg-amber-50/30 rounded-xl border border-amber-100 transition-hover hover:border-amber-200 hover:bg-white group">
      <div className="flex items-center gap-4">
        <div className="h-10 w-10 rounded-xl bg-amber-100 flex items-center justify-center text-amber-600">
          <AlertTriangle size={20}/>
        </div>
        <div>
          <p className="text-sm font-bold text-slate-700">Reclamación de {formatXAF(rev.amount_xaf)}</p>
          <p className="text-xs text-slate-500 italic truncate w-64 md:w-auto">"{rev.reversal_note}"</p>
          <p className="text-[10px] text-slate-400 mt-0.5">De: {rev.sender?.full_name} ({rev.sender?.phone})</p>
        </div>
      </div>
      <div className="flex gap-2">
        <button 
          onClick={() => onAction("process_reversal", { p_transaction_id: rev.id, p_approve: true, p_admin_note: "Aprobado" }, "Transacción revertida")}
          className="h-8 px-4 rounded-lg bg-emerald-600 text-white text-[10px] font-bold hover:bg-emerald-700 transition-colors shadow-sm"
        >
          Revertir
        </button>
        <button 
          onClick={() => onAction("process_reversal", { p_transaction_id: rev.id, p_approve: false, p_admin_note: "Infundada" }, "Reversión denegada")}
          className="h-8 px-4 rounded-lg bg-slate-200 text-slate-600 text-[10px] font-bold hover:bg-slate-300 transition-colors"
        >
          Desestimar
        </button>
      </div>
    </div>
  );
}
