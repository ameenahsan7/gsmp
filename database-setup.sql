-- ============================================
-- GSMP Database Setup
-- Run this in Supabase SQL Editor (left sidebar > SQL Editor)
-- ============================================

-- Chapters table (create FIRST — members references it)
CREATE TABLE public.chapters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  location TEXT NOT NULL,
  country TEXT NOT NULL,
  description TEXT DEFAULT '',
  lead_user_id UUID REFERENCES auth.users(id),
  member_count INT DEFAULT 0,
  status TEXT DEFAULT 'forming',
  founded_at TIMESTAMPTZ DEFAULT NOW()
);

-- Members table (extends Supabase auth.users)
CREATE TABLE public.members (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL,
  school TEXT NOT NULL,
  year TEXT NOT NULL,
  country TEXT NOT NULL,
  interests TEXT DEFAULT '',
  chapter_id UUID REFERENCES public.chapters(id),
  role TEXT DEFAULT 'member',
  is_founding BOOLEAN DEFAULT TRUE,
  joined_at TIMESTAMPTZ DEFAULT NOW()
);

-- Events table
CREATE TABLE public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT DEFAULT '',
  event_type TEXT DEFAULT 'workshop',
  event_date TIMESTAMPTZ NOT NULL,
  location TEXT DEFAULT 'Virtual',
  chapter_id UUID REFERENCES public.chapters(id),
  link TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Resources table
CREATE TABLE public.resources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  resource_type TEXT DEFAULT 'article',
  url TEXT DEFAULT '',
  author_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- Row Level Security (RLS) Policies
-- ============================================

-- Enable RLS on all tables
ALTER TABLE public.members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;

-- Members: users can read all members, but only update their own
CREATE POLICY "Anyone can view members" ON public.members FOR SELECT USING (true);
CREATE POLICY "Users can insert own member record" ON public.members FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own member record" ON public.members FOR UPDATE USING (auth.uid() = id);

-- Chapters: anyone can read, only leads can update
CREATE POLICY "Anyone can view chapters" ON public.chapters FOR SELECT USING (true);
CREATE POLICY "Authenticated users can create chapters" ON public.chapters FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY "Chapter leads can update" ON public.chapters FOR UPDATE USING (auth.uid() = lead_user_id);

-- Events: anyone can read
CREATE POLICY "Anyone can view events" ON public.events FOR SELECT USING (true);
CREATE POLICY "Authenticated users can create events" ON public.events FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- Resources: anyone can read
CREATE POLICY "Anyone can view resources" ON public.resources FOR SELECT USING (true);
CREATE POLICY "Authenticated users can create resources" ON public.resources FOR INSERT WITH CHECK (auth.role() = 'authenticated');

-- ============================================
-- Seed data: founding chapters
-- ============================================
INSERT INTO public.chapters (name, location, country, description, status, member_count) VALUES
  ('GSMP Johns Hopkins', 'Baltimore, MD', 'United States', 'The first GSMP chapter. Focused on clinical research skills, peer mentorship, and building a strong medical community.', 'active', 12),
  ('GSMP London (UCL)', 'London', 'United Kingdom', 'Bringing GSMP to London. Focused on global health, NHS career pathways, and cross-border collaboration.', 'forming', 7),
  ('GSMP AIIMS Delhi', 'New Delhi', 'India', 'India''s first GSMP chapter. Focused on medical research, USMLE/PLAB prep, and professional networking.', 'forming', 5),
  ('GSMP Dubai', 'Dubai', 'UAE', 'Connecting medical professionals across UAE institutions. Focused on healthcare innovation and regional networking.', 'forming', 4),
  ('GSMP Toronto (UofT)', 'Toronto', 'Canada', 'Building a chapter at one of Canada''s top medical schools. Focused on residency prep and interdisciplinary collaboration.', 'forming', 3);

-- Seed data: upcoming events
INSERT INTO public.events (title, description, event_type, event_date, location) VALUES
  ('Clinical Research 101: From Idea to Publication', 'A hands-on workshop for medical professionals looking to start or strengthen their research portfolio.', 'workshop', '2026-04-10T19:00:00Z', 'Virtual'),
  ('Beyond the Wards: Skills They Don''t Teach in Med School', 'Residents and attending physicians share the non-clinical skills that shaped their careers.', 'panel', '2026-04-18T18:00:00Z', 'Virtual'),
  ('GSMP Founding Members Meetup', 'Casual virtual hangout for founding members to connect, share ideas, and shape GSMP''s future.', 'social', '2026-04-25T20:00:00Z', 'Virtual');
