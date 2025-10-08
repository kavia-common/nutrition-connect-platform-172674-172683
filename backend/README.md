# Backend (Django) - Setup Notes

This folder contains dependency pins to ensure preview installers succeed.

Install:
  python -m venv .venv && . .venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt

Environment:
  Create a .env file with:
    DATABASE_URL=postgresql://nc_app:change_me_dev@localhost:5002/nutrition_connect
    SECRET_KEY=please_set_dev_secret
    DEBUG=1
    ALLOWED_HOSTS=*

Notes:
- psycopg2-binary is pinned to avoid system build dependencies.
- drf-spectacular is used for OpenAPI to avoid conflicts with drf-yasg.
- Channels and Daphne pins are compatible with Django 4.2.

The application code is not included in this step; this resolves dependency installation failures so previews can proceed.
