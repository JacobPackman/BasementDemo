"""FastAPI application for Wet Basement Services."""
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, Form, Depends
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqladmin import Admin
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

from models import init_db, engine, AsyncSessionLocal, SiteSetting, Service, Testimonial, Lead
from admin import AdminAuth, SiteSettingAdmin, ServiceAdmin, TestimonialAdmin, LeadAdmin

ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("ADMIN_PASS", "seattlewet123")
SECRET_KEY = os.getenv("SECRET_KEY", "wet-basement-ultra-secret-key-2026")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Setup database schema & initial seed data on startup
    await init_db()
    yield


app = FastAPI(title="Wet Basement Services", lifespan=lifespan)


@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    """Add HSTS and related hardening headers.

    Without Strict-Transport-Security, browsers show a "Not secure" indicator
    even on a valid certificate, because they have no instruction to require
    HTTPS for this host. The certificate itself is fine -- this is purely a
    browser-trust signal.

    Deliberately no includeSubDomains: this runs on a shared
    *.azurecontainerapps.io hostname, and HSTS on a shared parent domain is
    antisocial. max-age only applies to this exact host.
    """
    response = await call_next(request)
    response.headers["Strict-Transport-Security"] = "max-age=31536000"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response

# Azure Container Apps terminates TLS at the ingress and forwards PLAIN HTTP to
# the container. Without this, the app believes it is serving over http and
# generates http:// URLs -- including the admin login form's action and the
# post-login redirect. Browsers then block the login POST as mixed content and
# the user sees an "insecure form" warning before they even submit.
# Trust X-Forwarded-Proto so every generated URL is https.
app.add_middleware(ProxyHeadersMiddleware, trusted_hosts="*")

# Templates
templates = Jinja2Templates(directory="templates")

# Mount SQLAdmin (Dad's CMS dashboard)
authentication_backend = AdminAuth(secret_key=SECRET_KEY, admin_user=ADMIN_USER, admin_pass=ADMIN_PASS)
admin = Admin(
    app=app,
    engine=engine,
    title="WBS Management Portal",
    authentication_backend=authentication_backend,
    base_url="/admin"
)
admin.add_view(SiteSettingAdmin)
admin.add_view(ServiceAdmin)
admin.add_view(TestimonialAdmin)
admin.add_view(LeadAdmin)


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session


@app.get("/", response_class=HTMLResponse)
async def index(request: Request, db: AsyncSession = Depends(get_db)):
    # Fetch dynamic settings
    settings_res = await db.execute(select(SiteSetting))
    settings_dict = {s.key: s.value for s in settings_res.scalars().all()}

    # Fetch active services
    serv_res = await db.execute(
        select(Service).where(Service.is_active == True).order_by(Service.display_order.asc())
    )
    services = serv_res.scalars().all()

    # Fetch testimonials
    test_res = await db.execute(
        select(Testimonial).order_by(Testimonial.display_order.asc())
    )
    testimonials = test_res.scalars().all()

    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "settings": settings_dict,
            "services": services,
            "testimonials": testimonials,
        },
    )


@app.post("/quote", response_class=HTMLResponse)
async def submit_quote(
    request: Request,
    name: str = Form(...),
    phone: str = Form(...),
    email: str = Form(...),
    service_needed: str = Form("General Inspection"),
    address: str = Form(None),
    is_emergency: bool = Form(False),
    notes: str = Form(None),
    db: AsyncSession = Depends(get_db),
):
    # Save lead to database
    lead = Lead(
        name=name.strip(),
        phone=phone.strip(),
        email=email.strip(),
        address=address.strip() if address else None,
        is_emergency=is_emergency,
        service_needed=service_needed,
        notes=notes.strip() if notes else None,
        status="New",
    )
    db.add(lead)
    await db.commit()

    return templates.TemplateResponse(
        request=request,
        name="partials/quote_success.html",
        context={"lead": lead},
    )


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "wet-basement-services"}
