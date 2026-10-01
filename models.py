"""Database configuration, models, and initial seed data."""
import os
from datetime import datetime
from sqlalchemy import Column, Integer, String, Text, Boolean, DateTime
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import declarative_base

# The container sets DATABASE_URL explicitly (see docker-compose.yml and
# infra/main.bicep), so this default only applies to local dev and tests.
# Keep it strictly local: do NOT probe for /data, because on some hosts /data
# exists and is writable but belongs to something else entirely.
DB_PATH = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./wetbasement.db")

engine = create_async_engine(
    DB_PATH,
    echo=False,
    connect_args={"check_same_thread": False} if "sqlite" in DB_PATH else {},
)

AsyncSessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)

Base = declarative_base()


class SiteSetting(Base):
    """Global editable site settings (phone, emergency line, announcement, email)."""
    __tablename__ = "site_settings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    key = Column(String(64), unique=True, nullable=False, index=True)
    label = Column(String(128), nullable=False)
    value = Column(Text, nullable=False)

    def __str__(self):
        return f"{self.label} ({self.key})"


class Service(Base):
    """Services offered with icon, description, and highlights."""
    __tablename__ = "services"

    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(128), nullable=False)
    slug = Column(String(64), unique=True, nullable=False)
    tagline = Column(String(256), nullable=False)
    icon = Column(String(64), default="water")  # emoji or icon keyword
    description = Column(Text, nullable=False)
    badge = Column(String(64), default="Lifetime Warranty")
    display_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)

    def __str__(self):
        return self.title


class Testimonial(Base):
    """Customer reviews and real feedback."""
    __tablename__ = "testimonials"

    id = Column(Integer, primary_key=True, autoincrement=True)
    author = Column(String(128), nullable=False)
    location = Column(String(128), default="Seattle, WA")
    rating = Column(Integer, default=5)
    quote = Column(Text, nullable=False)
    verified = Column(Boolean, default=True)
    display_order = Column(Integer, default=0)

    def __str__(self):
        return f"{self.author} - {self.location} ({self.rating}★)"


class Lead(Base):
    """Customer intake / quote inquiries."""
    __tablename__ = "leads"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(128), nullable=False)
    phone = Column(String(64), nullable=False)
    email = Column(String(128), nullable=False)
    address = Column(String(256), nullable=True)
    is_emergency = Column(Boolean, default=False)
    service_needed = Column(String(128), default="Inspection")
    notes = Column(Text, nullable=True)
    status = Column(String(32), default="New")  # New, Contacted, Scheduled, Completed
    created_at = Column(DateTime, default=datetime.utcnow)

    def __str__(self):
        em = "[EMERGENCY] " if self.is_emergency else ""
        return f"{em}{self.name} - {self.phone} ({self.status})"


async def init_db():
    """Ensure database tables exist and seed baseline content if empty."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async with AsyncSessionLocal() as session:
        from sqlalchemy import select

        # Seed site settings if none exist
        res = await session.execute(select(SiteSetting))
        if not res.scalars().first():
            defaults = [
                SiteSetting(key="phone", label="Main Office Phone", value="(206) 555-0199"),
                SiteSetting(key="emergency_phone", label="24/7 Flood Hotline", value="(206) 555-WET1"),
                SiteSetting(key="email", label="Inquiry Email", value="contact@wetbasementservices.com"),
                SiteSetting(key="service_area", label="Service Area", value="Seattle, Bellevue, Redmond, Kirkland, Renton & Puget Sound"),
                SiteSetting(key="hero_headline", label="Homepage Hero Title", value="Permanent Basement Waterproofing & Mold Defense"),
                SiteSetting(key="hero_subtext", label="Homepage Subtitle", value="Science-based hydrology solutions backed by decades of PNW expertise and our personal Lifetime Transferable Warranty."),
                SiteSetting(key="years_experience", label="Years of Experience", value="40+"),
                SiteSetting(key="rating_badge", label="Awards & Recognition", value="Voted Best Restoration Company in the PNW 2025"),
            ]
            session.add_all(defaults)

        # Seed services if none exist
        s_res = await session.execute(select(Service))
        if not s_res.scalars().first():
            services = [
                Service(
                    title="Interior French Drains & Water Control",
                    slug="interior-water-control",
                    tagline="Desaturate sub-slab soils and permanently direct water away.",
                    icon="🌊",
                    badge="Lifetime Warranty",
                    description="Unlike band-aid competitors who just patch cracks, our deep interior drainage channels relieve hydraulic head pressure under your foundation slab permanently.",
                    display_order=1,
                    is_active=True,
                ),
                Service(
                    title="Dual Sump Pump & Battery Backups",
                    slug="sump-pumps",
                    tagline="Industrial pumping power with bulletproof power backup.",
                    icon="⚡",
                    badge="Heavy Duty",
                    description="Seattle atmospheric rivers knock out local power right when basements flood. Our dual-cast-iron pumps feature 72-hour smart battery backups.",
                    display_order=2,
                    is_active=True,
                ),
                Service(
                    title="Certified Mold Remediation",
                    slug="mold-remediation",
                    tagline="IICRC Certified Interior Environmental Professionals.",
                    icon="🛡️",
                    badge="IICRC Certified",
                    description="Moisture creates toxic fungal blooms. We treat the biological hazard using hospital-grade botanical antimicrobials and seal moisture entry pathways.",
                    display_order=3,
                    is_active=True,
                ),
                Service(
                    title="Vapor Barriers & Crawl Space Sealing",
                    slug="crawl-space-encapsulation",
                    tagline="Heavy-duty 20mil reinforced thermal encapsulation.",
                    icon="🏡",
                    badge="Energy Efficient",
                    description="Stop damp Puget Sound ground dampness from rotting your subflooring, raising heating bills, and invading your family's living areas.",
                    display_order=4,
                    is_active=True,
                ),
            ]
            session.add_all(services)

        # Seed testimonials if none exist
        t_res = await session.execute(select(Testimonial))
        if not t_res.scalars().first():
            testimonials = [
                Testimonial(
                    author="Michael W.",
                    location="Wallingford, Seattle",
                    rating=5,
                    quote="We've gone through our first winter, and a pretty wet one at that, since the work they did. It held up great and we didn't have any trouble with water intruding into the basement. No leaks, nothing!",
                    display_order=1,
                ),
                Testimonial(
                    author="Brittany C.",
                    location="Ballard, Seattle",
                    rating=5,
                    quote="Having my basement fixed by Jerzy and the team was one of the best decisions I've made since becoming a homeowner. Every time it rains, I'm so relieved we don't have to worry about water.",
                    display_order=2,
                ),
                Testimonial(
                    author="Kenneth B.",
                    location="Redmond, WA",
                    rating=5,
                    quote="John's knowledge blew everyone else out of the water. Other contractors just wanted to slap a quick patch on. John explained the exact hydrology and municipal code compliance. 10/10.",
                    display_order=3,
                ),
            ]
            session.add_all(testimonials)

        await session.commit()
