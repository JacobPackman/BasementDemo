"""SQLAdmin configuration providing Dad an easy-to-use CMS dashboard."""
from sqladmin import ModelView
from sqladmin.authentication import AuthenticationBackend
from starlette.requests import Request
from models import SiteSetting, Service, Testimonial, Lead


class AdminAuth(AuthenticationBackend):
    """Simple password-based session authentication for Dad's admin portal."""
    def __init__(self, secret_key: str, admin_user: str, admin_pass: str):
        super().__init__(secret_key=secret_key)
        self.admin_user = admin_user
        self.admin_pass = admin_pass

    async def login(self, request: Request) -> bool:
        form = await request.form()
        username = form.get("username")
        password = form.get("password")
        if username == self.admin_user and password == self.admin_pass:
            request.session.update({"token": "authenticated_dad_session"})
            return True
        return False

    async def logout(self, request: Request) -> bool:
        request.session.clear()
        return True

    async def authenticate(self, request: Request) -> bool:
        token = request.session.get("token")
        return token == "authenticated_dad_session"


class SiteSettingAdmin(ModelView, model=SiteSetting):
    name = "Site Setting"
    name_plural = "Site Settings (Phone, Headline, Info)"
    icon = "fa-solid fa-gear"
    column_list = [SiteSetting.label, SiteSetting.key, SiteSetting.value]
    column_searchable_list = [SiteSetting.label, SiteSetting.key]
    form_columns = [SiteSetting.label, SiteSetting.value]
    can_create = False
    can_delete = False


class ServiceAdmin(ModelView, model=Service):
    name = "Service"
    name_plural = "Services & Solutions"
    icon = "fa-solid fa-faucet-drip"
    column_list = [Service.title, Service.badge, Service.icon, Service.display_order, Service.is_active]
    column_sortable_list = [Service.display_order, Service.title]
    form_columns = [Service.title, Service.slug, Service.tagline, Service.icon, Service.badge, Service.description, Service.display_order, Service.is_active]


class TestimonialAdmin(ModelView, model=Testimonial):
    name = "Testimonial"
    name_plural = "Reviews & Testimonials"
    icon = "fa-solid fa-star"
    column_list = [Testimonial.author, Testimonial.location, Testimonial.rating, Testimonial.display_order]
    form_columns = [Testimonial.author, Testimonial.location, Testimonial.rating, Testimonial.quote, Testimonial.display_order]


class LeadAdmin(ModelView, model=Lead):
    name = "Lead"
    name_plural = "Customer Quote Inquiries"
    icon = "fa-solid fa-envelope-open-text"
    column_list = [Lead.created_at, Lead.name, Lead.phone, Lead.service_needed, Lead.is_emergency, Lead.status]
    column_sortable_list = [Lead.created_at, Lead.status, Lead.is_emergency]
    column_searchable_list = [Lead.name, Lead.phone, Lead.email]
    form_columns = [Lead.name, Lead.phone, Lead.email, Lead.address, Lead.service_needed, Lead.is_emergency, Lead.notes, Lead.status]
    can_create = True
    can_delete = True
