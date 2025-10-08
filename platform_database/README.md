# Platform Database

This container provides the PostgreSQL database for the Nutrition Connect Platform.

Key defaults:
- Host: localhost
- Port: 5002
- Database: nutrition_connect
- User: nc_app
- Password: change_me_dev

## Quick start

1) Run the startup script (idempotent):
   ./startup.sh

The script will:
- Ensure PostgreSQL is running and bound to 0.0.0.0 on port 5002
- Initialize PGDATA if needed and repair stale postmaster.pid
- Configure listen_addresses='*' and port=5002
- Update pg_hba.conf to allow local and remote md5 connections
- Create user nc_app and database nutrition_connect if they do not exist
- Grant appropriate privileges
- Wait for readiness using pg_isready with retries/backoff
- Write a connection helper to db_connection.txt
- Update db_visualizer/postgres.env with connection details

2) Verify readiness explicitly:
   pg_isready -h 127.0.0.1 -p 5002 -U nc_app

3) Connect with psql:
   psql -h localhost -U nc_app -d nutrition_connect -p 5002
or
   $(cat db_connection.txt)

4) Reference Schema and Seed
- schema.sql contains a comprehensive reference schema aligned with planned Django models.
- seed.sql contains minimal sample data for smoke testing.

Apply them manually if you need a local reference:
   psql -h localhost -U nc_app -d nutrition_connect -p 5002 -f schema.sql
   psql -h localhost -U nc_app -d nutrition_connect -p 5002 -f seed.sql

Note: Django migrations are the source of truth for the production database schema. The schema.sql here is a reference to help with development, tools, and visualization.

## Database Viewer (Optional)
An extremely simple DB viewer server is provided under db_visualizer.
- Environment file: db_visualizer/postgres.env (auto-populated by startup.sh)
- Start viewer:
  cd db_visualizer
  source postgres.env
  npm install
  npm start

Then navigate to http://localhost:3000 to explore tables and data.

## Connection URL
postgresql://nc_app:change_me_dev@localhost:5002/nutrition_connect
