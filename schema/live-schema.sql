-- ============================================================
-- GSMP — LIVE public schema snapshot (structure only, no data)
-- Captured: 2026-11-02 from Supabase project "GCMP" via catalog query
-- (pg_class / pg_constraint / pg_indexes / pg_proc / pg_trigger / pg_policies).
-- Includes storage.objects policies. Excludes Supabase-internal schemas.
--
-- This is the source of truth for what exists in production as of the
-- capture date. Changes after this go in migrations/. Re-capture after
-- any manual change in the dashboard.
-- ============================================================

-- ---------- TABLES ----------
CREATE TABLE public.activity_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamp with time zone DEFAULT now(),
  user_email text,
  category text NOT NULL,
  action text NOT NULL,
  details text
);

CREATE TABLE public.announcements (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  chapter_id uuid,
  author_id uuid NOT NULL,
  title text NOT NULL,
  body text NOT NULL DEFAULT ''::text,
  image_url text,
  is_pinned boolean NOT NULL DEFAULT false,
  expires_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.app_admins (
  email text NOT NULL,
  added_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.articles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  title text NOT NULL,
  category text NOT NULL DEFAULT 'news'::text,
  tag text,
  author text DEFAULT 'GSMP'::text,
  excerpt text,
  content text,
  image_url text,
  published boolean DEFAULT false,
  created_by text,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.chapters (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  country text NOT NULL,
  description text DEFAULT ''::text,
  lead_user_id uuid,
  member_count integer DEFAULT 0,
  status text DEFAULT 'forming'::text,
  founded_at timestamp with time zone DEFAULT now(),
  city text,
  created_by text
);

CREATE TABLE public.event_rsvps (
  id bigint NOT NULL,
  event_id uuid,
  member_id uuid,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text DEFAULT ''::text,
  event_type text DEFAULT 'workshop'::text,
  event_date timestamp with time zone NOT NULL,
  location text DEFAULT 'Virtual'::text,
  chapter_id uuid,
  link text DEFAULT ''::text,
  created_at timestamp with time zone DEFAULT now(),
  show_in_portal boolean DEFAULT true,
  created_by text,
  image_url text
);

CREATE TABLE public.gallery_albums (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  event_date date,
  chapter_id uuid,
  cover_url text,
  created_by text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.gallery_photos (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  album_id uuid NOT NULL,
  image_url text NOT NULL,
  caption text,
  display_order integer NOT NULL DEFAULT 0,
  created_by text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE public.members (
  id uuid NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  email text NOT NULL,
  school text NOT NULL,
  year text NOT NULL,
  country text NOT NULL,
  interests text DEFAULT ''::text,
  chapter_id uuid,
  role text DEFAULT 'member'::text,
  is_founding boolean DEFAULT true,
  joined_at timestamp with time zone DEFAULT now(),
  referred_by text,
  referral_code text,
  phone text,
  gender text,
  degree text,
  field text,
  specialty text,
  city text,
  member_title text DEFAULT 'Member'::text
);

CREATE TABLE public.referral_codes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  note text,
  max_uses integer DEFAULT 0,
  times_used integer DEFAULT 0,
  active boolean DEFAULT true,
  chapter_id uuid,
  created_by text
);

CREATE TABLE public.resources (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  title text NOT NULL,
  resource_type text DEFAULT 'article'::text,
  url text DEFAULT ''::text,
  author_id uuid,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.shop_items (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  category text DEFAULT 'Branded Gear'::text,
  price text,
  description text,
  image_url text,
  sort_order integer DEFAULT 0,
  active boolean DEFAULT true,
  created_by text,
  created_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.site_settings (
  key text NOT NULL,
  value text,
  updated_at timestamp with time zone DEFAULT now()
);

-- ---------- CONSTRAINTS ----------
ALTER TABLE activity_logs ADD CONSTRAINT activity_logs_pkey PRIMARY KEY (id);
ALTER TABLE announcements ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);
ALTER TABLE announcements ADD CONSTRAINT announcements_author_id_fkey FOREIGN KEY (author_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE announcements ADD CONSTRAINT announcements_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES chapters(id) ON DELETE CASCADE;
ALTER TABLE announcements ADD CONSTRAINT announcements_body_check CHECK ((char_length(body) <= 4000));
ALTER TABLE announcements ADD CONSTRAINT announcements_title_check CHECK (((char_length(title) >= 1) AND (char_length(title) <= 160)));
ALTER TABLE app_admins ADD CONSTRAINT app_admins_pkey PRIMARY KEY (email);
ALTER TABLE articles ADD CONSTRAINT articles_pkey PRIMARY KEY (id);
ALTER TABLE chapters ADD CONSTRAINT chapters_pkey PRIMARY KEY (id);
ALTER TABLE event_rsvps ADD CONSTRAINT event_rsvps_pkey PRIMARY KEY (id);
ALTER TABLE event_rsvps ADD CONSTRAINT event_rsvps_event_id_fkey FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE;
ALTER TABLE event_rsvps ADD CONSTRAINT event_rsvps_member_id_fkey FOREIGN KEY (member_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE event_rsvps ADD CONSTRAINT event_rsvps_event_id_member_id_key UNIQUE (event_id, member_id);
ALTER TABLE events ADD CONSTRAINT events_pkey PRIMARY KEY (id);
ALTER TABLE events ADD CONSTRAINT events_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES chapters(id);
ALTER TABLE gallery_albums ADD CONSTRAINT gallery_albums_pkey PRIMARY KEY (id);
ALTER TABLE gallery_albums ADD CONSTRAINT gallery_albums_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES chapters(id) ON DELETE CASCADE;
ALTER TABLE gallery_photos ADD CONSTRAINT gallery_photos_pkey PRIMARY KEY (id);
ALTER TABLE gallery_photos ADD CONSTRAINT gallery_photos_album_id_fkey FOREIGN KEY (album_id) REFERENCES gallery_albums(id) ON DELETE CASCADE;
ALTER TABLE members ADD CONSTRAINT members_pkey PRIMARY KEY (id);
ALTER TABLE members ADD CONSTRAINT members_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE members ADD CONSTRAINT members_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES chapters(id) ON DELETE SET NULL;
ALTER TABLE members ADD CONSTRAINT members_referral_code_key UNIQUE (referral_code);
ALTER TABLE referral_codes ADD CONSTRAINT referral_codes_pkey PRIMARY KEY (id);
ALTER TABLE referral_codes ADD CONSTRAINT referral_codes_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES chapters(id);
ALTER TABLE referral_codes ADD CONSTRAINT referral_codes_code_key UNIQUE (code);
ALTER TABLE resources ADD CONSTRAINT resources_pkey PRIMARY KEY (id);
ALTER TABLE resources ADD CONSTRAINT resources_author_id_fkey FOREIGN KEY (author_id) REFERENCES auth.users(id);
ALTER TABLE shop_items ADD CONSTRAINT shop_items_pkey PRIMARY KEY (id);
ALTER TABLE site_settings ADD CONSTRAINT site_settings_pkey PRIMARY KEY (key);

-- ---------- INDEXES (non-PK) ----------
CREATE INDEX idx_activity_logs_category ON public.activity_logs USING btree (category);
CREATE INDEX idx_activity_logs_created ON public.activity_logs USING btree (created_at DESC);
CREATE INDEX idx_announcements_author ON public.announcements USING btree (author_id);
CREATE INDEX idx_announcements_chapter ON public.announcements USING btree (chapter_id);
CREATE INDEX idx_announcements_pinned_created ON public.announcements USING btree (is_pinned DESC, created_at DESC);
CREATE INDEX idx_gallery_albums_chapter ON public.gallery_albums USING btree (chapter_id);
CREATE INDEX idx_gallery_albums_date ON public.gallery_albums USING btree (event_date DESC NULLS LAST);
CREATE INDEX idx_gallery_photos_album ON public.gallery_photos USING btree (album_id, display_order);
-- (unique indexes backing UNIQUE constraints are created by the constraints above)

-- ---------- FUNCTIONS ----------
CREATE OR REPLACE FUNCTION public.is_saas_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.app_admins a
    JOIN auth.users u ON u.email = a.email
    WHERE u.id = auth.uid()
  );
$function$;

CREATE OR REPLACE FUNCTION public.gsmp_my_chapter()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT chapter_id FROM public.members WHERE id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.gsmp_is_chapter_lead()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.members
                 WHERE id = auth.uid() AND member_title = 'Chapter Lead');
$function$;

CREATE OR REPLACE FUNCTION public.gsmp_can_claim_member(p_id uuid, p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  SELECT EXISTS (SELECT 1 FROM auth.users u
                 WHERE u.id = p_id
                   AND lower(u.email) = lower(p_email)
                   AND u.created_at > now() - interval '1 day');
$function$;

CREATE OR REPLACE FUNCTION public.get_member_card(p_code text)
 RETURNS TABLE(first_name text, last_name text, school text, year text, country text, city text, email text, phone text, chapter_id uuid, degree text, field text, specialty text, member_title text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT m.first_name, m.last_name, m.school, m.year, m.country, m.city, m.email,
         m.phone, m.chapter_id, m.degree, m.field, m.specialty, m.member_title
  FROM public.members m
  WHERE m.referral_code = upper(p_code) AND length(p_code) >= 6
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.gsmp_guard_member_privileges()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- service role / SQL editor (no JWT) and SaaS admins are unrestricted
  IF auth.uid() IS NULL AND TG_OP = 'UPDATE' THEN RETURN NEW; END IF;
  IF public.is_saas_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.member_title := NULL;          -- shows as 'Member'
    RETURN NEW;
  END IF;

  IF NEW.member_title IS DISTINCT FROM OLD.member_title THEN
    IF NOT (public.gsmp_is_chapter_lead()
            AND OLD.id <> auth.uid()
            AND OLD.chapter_id = public.gsmp_my_chapter()
            AND NEW.member_title IN ('Member','Active Member','Senior Member','Ambassador')) THEN
      RAISE EXCEPTION 'Not allowed to change member_title';
    END IF;
  END IF;

  IF NEW.chapter_id IS DISTINCT FROM OLD.chapter_id AND NOT public.gsmp_is_chapter_lead() THEN
    RAISE EXCEPTION 'Not allowed to change chapter';
  END IF;

  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.create_personal_referral_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.referral_code IS NOT NULL THEN
    INSERT INTO public.referral_codes
      (code, note, max_uses, times_used, active, chapter_id, created_by)
    VALUES
      (NEW.referral_code,
       'Auto: ' || COALESCE(NEW.first_name,'') || ' ' || COALESCE(NEW.last_name,''),
       0,
       0,
       true,
       NEW.chapter_id,
       NEW.email)
    ON CONFLICT (code) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_and_use_referral_code(p_code text)
 RETURNS TABLE(is_valid boolean, chapter_id uuid, error_message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_code     public.referral_codes%ROWTYPE;
  v_chapter  UUID;
BEGIN
  SELECT * INTO v_code
  FROM public.referral_codes
  WHERE code = p_code AND active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'Invalid or expired referral code.'::TEXT;
    RETURN;
  END IF;

  IF v_code.max_uses IS NOT NULL
     AND v_code.max_uses > 0
     AND v_code.times_used >= v_code.max_uses THEN
    RETURN QUERY SELECT FALSE, NULL::UUID, 'This referral code has reached its usage limit.'::TEXT;
    RETURN;
  END IF;

  -- Resolve chapter: prefer code's chapter; otherwise use referrer member's chapter.
  v_chapter := v_code.chapter_id;
  IF v_chapter IS NULL THEN
    SELECT m.chapter_id INTO v_chapter
    FROM public.members m
    WHERE m.referral_code = p_code
    LIMIT 1;
  END IF;

  UPDATE public.referral_codes
  SET times_used = times_used + 1
  WHERE id = v_code.id;

  RETURN QUERY SELECT TRUE, v_chapter, NULL::TEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.touch_gallery_album_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

-- ---------- TRIGGERS ----------
CREATE TRIGGER announcements_updated_at BEFORE UPDATE ON public.announcements FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER gallery_albums_touch BEFORE UPDATE ON public.gallery_albums FOR EACH ROW EXECUTE FUNCTION touch_gallery_album_updated_at();
CREATE TRIGGER gsmp_guard_member_privileges BEFORE INSERT OR UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION gsmp_guard_member_privileges();
CREATE TRIGGER members_create_personal_code AFTER INSERT ON public.members FOR EACH ROW EXECUTE FUNCTION create_personal_referral_code();

-- ---------- ROW LEVEL SECURITY ----------
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.articles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_rsvps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gallery_albums ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gallery_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.site_settings ENABLE ROW LEVEL SECURITY;

-- ---------- POLICIES ----------
-- activity_logs
CREATE POLICY "Admins can read logs" ON public.activity_logs FOR SELECT TO authenticated USING (is_saas_admin());
CREATE POLICY "Authenticated users can insert logs" ON public.activity_logs FOR INSERT TO authenticated WITH CHECK (true);

-- announcements
CREATE POLICY "Authors can delete own announcements" ON public.announcements FOR DELETE TO public USING (((author_id = auth.uid()) OR is_saas_admin()));
CREATE POLICY "Authors can insert announcements" ON public.announcements FOR INSERT TO public WITH CHECK (((author_id = auth.uid()) AND (is_saas_admin() OR ((chapter_id IS NOT NULL) AND (chapter_id = ( SELECT members.chapter_id
   FROM members
  WHERE (members.id = auth.uid()))) AND (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text]))))));
CREATE POLICY "Authors can update own announcements" ON public.announcements FOR UPDATE TO public USING (((author_id = auth.uid()) OR is_saas_admin())) WITH CHECK ((((author_id = auth.uid()) OR is_saas_admin()) AND (is_saas_admin() OR ((chapter_id IS NOT NULL) AND (chapter_id = ( SELECT members.chapter_id
   FROM members
  WHERE (members.id = auth.uid()))) AND (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text]))))));
CREATE POLICY "Visible announcements" ON public.announcements FOR SELECT TO public USING ((is_saas_admin() OR (chapter_id IS NULL) OR (chapter_id = ( SELECT members.chapter_id
   FROM members
  WHERE (members.id = auth.uid())))));

-- app_admins
CREATE POLICY "Admins can view admin list" ON public.app_admins FOR SELECT TO public USING ((EXISTS ( SELECT 1
   FROM auth.users u
  WHERE ((u.id = auth.uid()) AND ((u.email)::text = app_admins.email)))));

-- articles
CREATE POLICY "Admins full access articles" ON public.articles FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can read published articles" ON public.articles FOR SELECT TO public USING ((published = true));

-- chapters
CREATE POLICY "Admins full access chapters" ON public.chapters FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can view chapters" ON public.chapters FOR SELECT TO public USING (true);
CREATE POLICY "Chapter leads can create chapters" ON public.chapters FOR INSERT TO public WITH CHECK (gsmp_is_chapter_lead());
CREATE POLICY "Chapter leads can update own chapter" ON public.chapters FOR UPDATE TO public USING ((gsmp_is_chapter_lead() AND (id = gsmp_my_chapter()))) WITH CHECK ((gsmp_is_chapter_lead() AND (id = gsmp_my_chapter())));

-- event_rsvps
CREATE POLICY "Admins full access rsvps" ON public.event_rsvps FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can view rsvps" ON public.event_rsvps FOR SELECT TO public USING (true);
CREATE POLICY "Users can cancel own rsvp" ON public.event_rsvps FOR DELETE TO public USING ((auth.uid() = member_id));
CREATE POLICY "Users can delete own RSVP" ON public.event_rsvps FOR DELETE TO public USING ((auth.uid() = member_id));
CREATE POLICY "Users can insert own RSVP" ON public.event_rsvps FOR INSERT TO public WITH CHECK ((auth.uid() = member_id));
CREATE POLICY "Users can read all RSVPs" ON public.event_rsvps FOR SELECT TO public USING (true);
CREATE POLICY "Users can rsvp" ON public.event_rsvps FOR INSERT TO public WITH CHECK ((auth.uid() = member_id));

-- events
CREATE POLICY "Admins full access events" ON public.events FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can view events" ON public.events FOR SELECT TO public USING (true);
CREATE POLICY "Chapter leads can create events" ON public.events FOR INSERT TO public WITH CHECK ((EXISTS ( SELECT 1
   FROM members
  WHERE ((members.id = auth.uid()) AND (members.member_title = 'Chapter Lead'::text)))));
CREATE POLICY "Chapter leads can delete own events" ON public.events FOR DELETE TO public USING (((created_by = (auth.jwt() ->> 'email'::text)) AND (EXISTS ( SELECT 1
   FROM members
  WHERE ((members.id = auth.uid()) AND (members.member_title = 'Chapter Lead'::text))))));
CREATE POLICY "Chapter leads can update own events" ON public.events FOR UPDATE TO public USING (((created_by = (auth.jwt() ->> 'email'::text)) AND (EXISTS ( SELECT 1
   FROM members
  WHERE ((members.id = auth.uid()) AND (members.member_title = 'Chapter Lead'::text))))));

-- gallery_albums
CREATE POLICY "Organizers can delete own albums" ON public.gallery_albums FOR DELETE TO public USING (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (created_by = ( SELECT members.email
   FROM members
  WHERE (members.id = auth.uid()))))));
CREATE POLICY "Organizers can insert albums" ON public.gallery_albums FOR INSERT TO public WITH CHECK (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text])))));
CREATE POLICY "Organizers can update own albums" ON public.gallery_albums FOR UPDATE TO public USING (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (created_by = ( SELECT members.email
   FROM members
  WHERE (members.id = auth.uid()))))));
CREATE POLICY "Public can view albums" ON public.gallery_albums FOR SELECT TO public USING (true);

-- gallery_photos
CREATE POLICY "Organizers can delete own photos" ON public.gallery_photos FOR DELETE TO public USING (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (created_by = ( SELECT members.email
   FROM members
  WHERE (members.id = auth.uid()))))));
CREATE POLICY "Organizers can insert photos" ON public.gallery_photos FOR INSERT TO public WITH CHECK (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (EXISTS ( SELECT 1
   FROM (gallery_albums a
     JOIN members m ON ((m.id = auth.uid())))
  WHERE ((a.id = gallery_photos.album_id) AND (m.member_title = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text])) AND ((a.chapter_id IS NULL) OR (a.chapter_id = m.chapter_id))))))));
CREATE POLICY "Organizers can update own photos" ON public.gallery_photos FOR UPDATE TO public USING (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (created_by = ( SELECT members.email
   FROM members
  WHERE (members.id = auth.uid()))))));
CREATE POLICY "Public can view photos" ON public.gallery_photos FOR SELECT TO public USING (true);

-- members
CREATE POLICY "Admins full access members" ON public.members FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Chapter leads can update members in their chapter" ON public.members FOR UPDATE TO public USING ((chapter_id IN ( SELECT members_1.chapter_id
   FROM members members_1
  WHERE ((members_1.id = auth.uid()) AND (members_1.member_title = 'Chapter Lead'::text))))) WITH CHECK ((chapter_id IN ( SELECT members_1.chapter_id
   FROM members members_1
  WHERE ((members_1.id = auth.uid()) AND (members_1.member_title = 'Chapter Lead'::text)))));
CREATE POLICY "Chapter leads can view own chapter members" ON public.members FOR SELECT TO public USING ((gsmp_is_chapter_lead() AND (chapter_id = gsmp_my_chapter())));
CREATE POLICY "New signups can create own profile" ON public.members FOR INSERT TO public WITH CHECK (gsmp_can_claim_member(id, email));
CREATE POLICY "Users can insert own record" ON public.members FOR INSERT TO public WITH CHECK ((auth.uid() = id));
CREATE POLICY "Users can update own record" ON public.members FOR UPDATE TO public USING ((auth.uid() = id));
CREATE POLICY "Users can view own record" ON public.members FOR SELECT TO public USING ((auth.uid() = id));

-- referral_codes
CREATE POLICY "Admins full access referral codes" ON public.referral_codes FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Chapter leads can manage own chapter codes" ON public.referral_codes FOR ALL TO public USING ((gsmp_is_chapter_lead() AND (chapter_id = gsmp_my_chapter()))) WITH CHECK ((gsmp_is_chapter_lead() AND (chapter_id = gsmp_my_chapter())));
CREATE POLICY "Members can view chapter codes" ON public.referral_codes FOR SELECT TO public USING (((auth.uid() IS NOT NULL) AND (is_saas_admin() OR (chapter_id = ( SELECT members.chapter_id
   FROM members
  WHERE (members.id = auth.uid()))))));

-- resources
CREATE POLICY "Anyone can view resources" ON public.resources FOR SELECT TO public USING (true);
CREATE POLICY "Authenticated users can create resources" ON public.resources FOR INSERT TO public WITH CHECK ((auth.role() = 'authenticated'::text));

-- shop_items
CREATE POLICY "Admins full access shop items" ON public.shop_items FOR ALL TO public USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can view active shop items" ON public.shop_items FOR SELECT TO public USING (true);

-- site_settings
CREATE POLICY "Admins can modify site settings" ON public.site_settings FOR ALL TO authenticated USING (is_saas_admin()) WITH CHECK (is_saas_admin());
CREATE POLICY "Anyone can read site settings" ON public.site_settings FOR SELECT TO public USING (true);

-- storage.objects (buckets: announcement-images, event-images, gallery-images — all public read)
CREATE POLICY "Authors can delete own announcement images" ON storage.objects FOR DELETE TO public USING (((bucket_id = 'announcement-images'::text) AND ((owner = auth.uid()) OR is_saas_admin())));
CREATE POLICY "Authors can upload announcement images" ON storage.objects FOR INSERT TO public WITH CHECK (((bucket_id = 'announcement-images'::text) AND (auth.uid() IS NOT NULL) AND (is_saas_admin() OR (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text])))));
CREATE POLICY "Event organizers can upload images" ON storage.objects FOR INSERT TO public WITH CHECK (((bucket_id = 'event-images'::text) AND (auth.uid() IS NOT NULL) AND (is_saas_admin() OR (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text])))));
CREATE POLICY "Organizers can upload gallery images" ON storage.objects FOR INSERT TO public WITH CHECK (((bucket_id = 'gallery-images'::text) AND (auth.uid() IS NOT NULL) AND (is_saas_admin() OR (( SELECT members.member_title
   FROM members
  WHERE (members.id = auth.uid())) = ANY (ARRAY['Chapter Lead'::text, 'Fellow'::text])))));
CREATE POLICY "Owners can delete own event images" ON storage.objects FOR DELETE TO public USING (((bucket_id = 'event-images'::text) AND ((owner = auth.uid()) OR is_saas_admin())));
CREATE POLICY "Owners can delete own gallery images" ON storage.objects FOR DELETE TO public USING (((bucket_id = 'gallery-images'::text) AND ((owner = auth.uid()) OR is_saas_admin())));
CREATE POLICY "Public can view announcement images" ON storage.objects FOR SELECT TO public USING ((bucket_id = 'announcement-images'::text));
CREATE POLICY "Public can view event images" ON storage.objects FOR SELECT TO public USING ((bucket_id = 'event-images'::text));
CREATE POLICY "Public can view gallery images" ON storage.objects FOR SELECT TO public USING ((bucket_id = 'gallery-images'::text));
