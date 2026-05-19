import { createClient } from '@supabase/supabase-js'

const supabaseUrl = 'https://xxjkmtxlpfibsrswbnorc.supabase.co'
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh4amtteGxwZmlic3Jzd2Jub3JjIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTE5NDI4OCwiZXhwIjoyMDk0NzcwMjg4fQ.FjNnStwl3EZZGMiqSVjs_8-U9t-wYSoSzsFjNax_T1w'
const supabase = createClient(supabaseUrl, supabaseKey)

async function listUsers() {
  const { data, error } = await supabase.from('profiles').select('full_name, phone, role, email_dummy:id')
  if (error) {
    console.error('Error:', error)
    return
  }
  console.log('Usuarios encontrados:', JSON.stringify(data, null, 2))
}

listUsers()
