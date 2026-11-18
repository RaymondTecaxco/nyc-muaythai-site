# The Kru: NYC Muay Thai Companion App (Frontend)

## Overview
This repository contains the frontend web application for "The Kru," an automated NYC combat sports aggregator. While the backend ETL pipeline, (https://github.com/RaymondTecaxco/muaythai-aggregator), handles the heavy lifting of extracting and standardizing disparate fight data, this Next.js site serves as the live, user-facing directory.

## Built With
*   **Next.js (App Router):** Uses standard JavaScript and server-side rendering to generate pages based on real-time database queries.
*   **Tailwind CSS:** Used for rapid UI development, transforming raw text data into clean, mobile-friendly event cards.
*   **Supabase Client (`@supabase/supabase-js`):** Connects directly to the cloud PostgreSQL database to fetch the latest scraped events.
*   **Vercel:** Handles continuous deployment, automatically rebuilding and updating the live site with every push to the main branch.

## Technical Hurdles: Taming the Cache
One of the immediate challenges of building with the Next.js app router is its aggressive default caching. Because the main feed was built as a server component, Next.js initially took a static "snapshot" of the database during the Vercel build. This caused the live site to show stale event data even after the backend scraper had already run and updated the database.

To solve this, I implemented `export const dynamic = 'force-dynamic'` to explicitly bypass the cache. This forces the server to fetch fresh Supabase rows on every single page load, ensuring the community always sees the most up-to-date fight calendar.

## Future Roadmap (Version 2.0)
This site is currently in its Phase 1 prototype state, serving primarily as a unified event feed. Future features currently in my Agile backlog include:
*   A secure exhibition matchmaker board requiring role-based coach login authentication.
*   An interactive NYC gym and combat retail map.
*   A Twilio-powered SMS alert opt-in portal for seminars hosted by veterans in the sport.

## Local Setup
1. Clone this repository: `git clone https://github.com/RaymondTecaxco/nyc-muaythai-site.git`
2. Install dependencies: `npm install`
3. Create a `.env.local` file at the root with your Supabase credentials:
   NEXT_PUBLIC_SUPABASE_URL=your_url
   NEXT_PUBLIC_SUPABASE_ANON_KEY=your_key
4. Run the development server: `npm run dev`
5. Open http://localhost:3000 in your browser.

## Database Migrations
Every change to the matchmaker's database structure lives in `supabase/migrations/` as a SQL file, so the schema is versioned in Git alongside the code. Files are named with a timestamp (for example `20261118170137_create_updated_at_helper.sql`) and are applied in that order. Never edit a migration that has already been applied; write a new one instead.

The Supabase CLI is installed as a dev dependency, so no global install is needed.

**One-time setup (per computer)**
1. Log in to Supabase: `npx supabase login`
2. Link this folder to the project (find the project ref in your Supabase dashboard URL): `npx supabase link --project-ref your_project_ref`
   Linking only records which project to use. No database password is needed: the CLI uses the access token from `supabase login` to create a temporary login role for each command. You can revoke that token anytime in the Supabase dashboard under Account → Access Tokens.

**Everyday workflow**
1. Create a new, empty migration: `npm run db:new -- describe_the_change`
2. Write the SQL in the new file under `supabase/migrations/`.
3. Check which migrations the remote database has already applied: `npm run db:status`
4. Apply pending migrations to Supabase: `npm run db:push`

Both `db:status` and `db:push` pass `--remote`, because the Supabase CLI targets a local Docker database by default. This project uses the hosted Supabase database only.

**Note:** the `events` table and `upcoming_events` view are created by the [aggregator repo](https://github.com/RaymondTecaxco/muaythai-aggregator) (`sql/upcoming_events_view.sql`), not by these migrations.