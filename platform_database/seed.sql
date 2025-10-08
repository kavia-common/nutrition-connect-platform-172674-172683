BEGIN;

-- Minimal seed data for smoke testing

-- Users
INSERT INTO user_profiles (id, email, role, first_name, last_name)
VALUES
  (uuid_generate_v4(), 'admin@example.com', 'admin', 'Ada', 'Admin'),
  (uuid_generate_v4(), 'coach@example.com', 'coach', 'Chris', 'Coach'),
  (uuid_generate_v4(), 'client@example.com', 'client', 'Casey', 'Client')
ON CONFLICT (email) DO NOTHING;

-- Link client to coach
WITH coach AS (
  SELECT id AS coach_id FROM user_profiles WHERE email='coach@example.com'
),
client_user AS (
  SELECT id AS user_id FROM user_profiles WHERE email='client@example.com'
)
INSERT INTO client_profiles (user_id, coach_id, onboarding_status)
SELECT cu.user_id, c.coach_id, 'completed'
FROM coach c, client_user cu
ON CONFLICT (user_id) DO NOTHING;

-- Foods
INSERT INTO foods (name, brand, serving_size, serving_unit, calories, protein, carbs, fat)
VALUES
  ('Chicken Breast', 'Generic', 100, 'g', 165, 31, 0, 3.6),
  ('Brown Rice (Cooked)', 'Generic', 100, 'g', 123, 2.7, 25.6, 1.0),
  ('Broccoli', 'Generic', 100, 'g', 34, 2.8, 7.0, 0.4)
ON CONFLICT DO NOTHING;

-- Recipe and ingredients
WITH r AS (
  INSERT INTO recipes (name, description, total_servings, visibility)
  VALUES ('Chicken and Rice Bowl', 'Simple high-protein meal', 2, 'public')
  RETURNING id
), f AS (
  SELECT id, name FROM foods WHERE name IN ('Chicken Breast','Brown Rice (Cooked)','Broccoli')
)
INSERT INTO recipe_ingredients (recipe_id, food_id, ingredient_name, quantity, unit, position)
SELECT r.id, f1.id, 'Chicken Breast', 200, 'g', 1 FROM r, (SELECT id FROM foods WHERE name='Chicken Breast') f1
UNION ALL
SELECT r.id, f2.id, 'Brown Rice', 200, 'g', 2 FROM r, (SELECT id FROM foods WHERE name='Brown Rice (Cooked)') f2
UNION ALL
SELECT r.id, f3.id, 'Broccoli', 150, 'g', 3 FROM r, (SELECT id FROM foods WHERE name='Broccoli') f3;

-- Exercise and workout
INSERT INTO exercises (name, category) VALUES
  ('Push-up', 'bodyweight'),
  ('Squat', 'bodyweight')
ON CONFLICT DO NOTHING;

WITH w AS (
  INSERT INTO workouts (name, description, visibility)
  VALUES ('Starter Workout', 'Beginner-friendly routine', 'public')
  RETURNING id
)
INSERT INTO workout_exercises (workout_id, exercise_id, position, sets, reps, rest_seconds)
SELECT w.id, e.id, ROW_NUMBER() OVER ()::int, 3, 10, 60
FROM w, (SELECT id FROM exercises WHERE name IN ('Push-up','Squat')) e;

-- Habit and assignment
WITH h AS (
  INSERT INTO habits (title, description, frequency, target_value, target_unit)
  VALUES ('Drink Water', 'Have at least 8 cups of water', 'daily', 8, 'cups')
  RETURNING id
), client_u AS (
  SELECT id AS client_id FROM user_profiles WHERE email='client@example.com'
)
INSERT INTO habit_assignments (habit_id, client_id, start_date, active)
SELECT h.id, client_u.client_id, CURRENT_DATE, TRUE FROM h, client_u
ON CONFLICT DO NOTHING;

-- Plan and item
WITH plan AS (
  INSERT INTO plans (client_id, title, start_date, status)
  SELECT id, 'Kickoff Plan', CURRENT_DATE, 'active'
  FROM user_profiles WHERE email='client@example.com'
  RETURNING id
)
INSERT INTO plan_items (plan_id, item_type, scheduled_at, notes)
SELECT id, 'note', NOW(), 'Welcome to your plan!'
FROM plan;

-- Conversation and welcome message
WITH conv AS (
  INSERT INTO conversations (coach_id, client_id, topic, status)
  SELECT c.id, cl.id, 'Onboarding', 'open'
  FROM user_profiles c, user_profiles cl
  WHERE c.email='coach@example.com' AND cl.email='client@example.com'
  ON CONFLICT (coach_id, client_id) DO UPDATE SET topic=EXCLUDED.topic
  RETURNING id
), coach AS (
  SELECT id FROM user_profiles WHERE email='coach@example.com'
)
INSERT INTO messages (conversation_id, sender_id, content)
SELECT conv.id, coach.id, 'Welcome! Excited to get started.'
FROM conv, coach
ON CONFLICT DO NOTHING;

COMMIT;
