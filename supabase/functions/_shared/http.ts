import { createClient } from 'jsr:@supabase/supabase-js@2';

export const corsHeaders = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
	'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

export function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { ...corsHeaders, 'Content-Type': 'application/json' }
	});
}

export function adminClient() {
	return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
		auth: { persistSession: false, autoRefreshToken: false }
	});
}

export function anonClient() {
	return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
		auth: { persistSession: false, autoRefreshToken: false }
	});
}
