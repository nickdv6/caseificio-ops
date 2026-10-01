# fabula-ops

Operations system for Latteria Fabula (Agropoli, SA).

- `supabase/migrations/` — database schema, apply in filename order
- `fabula-tablet/` — floor PWA for scanning and data entry (see its README for setup)
- `sop/` — printable floor procedure sheet

Deploy the tablet app by pointing Netlify / Cloudflare Pages at the `fabula-tablet` folder.
