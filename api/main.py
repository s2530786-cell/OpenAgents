"""
@contributor: wangcai-openclaw (旺财)
@platform: OpenClaw + DeepSeek V4 Pro agent
@runtime: Windows_NT 10.0.19045 x64 | D:\openclaw-data\workspace\repos\OpenAgents | powershell
@date: 2026-05-21T01:20:00+08:00
"""
import os
import shutil
import time
import psutil
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional
from datetime import datetime
from api.models.database import SessionLocal

app = FastAPI(
    title="OpenAgents API",
    description="Off-chain indexer and agent discovery API for the OpenAgents protocol",
    version="0.1.0",
)


class AgentResponse(BaseModel):
    agent_id: str
    name: str
    owner: str
    endpoint: str
    reputation: int
    tasks_completed: int
    registered_at: datetime
    active: bool


class TaskResponse(BaseModel):
    task_id: int
    creator: str
    description: str
    reward_wei: str
    deadline: datetime
    status: str
    assigned_agent: Optional[str] = None


class LeaderboardEntry(BaseModel):
    agent_id: str
    name: str
    reputation: int
    tasks_completed: int
    success_rate: float


# In-memory store (placeholder for DB)
agents_cache: dict = {}
tasks_cache: dict = {}


@app.get("/agents", response_model=list[AgentResponse])
async def list_agents(
    active_only: bool = Query(True),
    min_reputation: int = Query(0),
    limit: int = Query(50, le=100),
    offset: int = Query(0),
):
    results = list(agents_cache.values())
    if active_only:
        results = [a for a in results if a.get("active")]
    results = [a for a in results if a.get("reputation", 0) >= min_reputation]
    return results[offset : offset + limit]


@app.get("/agents/{agent_id}", response_model=AgentResponse)
async def get_agent(agent_id: str):
    if agent_id not in agents_cache:
        raise HTTPException(status_code=404, detail="Agent not found")
    return agents_cache[agent_id]


@app.get("/tasks", response_model=list[TaskResponse])
async def list_tasks(
    status: Optional[str] = Query(None),
    limit: int = Query(50, le=100),
    offset: int = Query(0),
):
    results = list(tasks_cache.values())
    if status:
        results = [t for t in results if t.get("status") == status]
    return results[offset : offset + limit]


@app.get("/tasks/{task_id}", response_model=TaskResponse)
async def get_task(task_id: int):
    if task_id not in tasks_cache:
        raise HTTPException(status_code=404, detail="Task not found")
    return tasks_cache[task_id]


@app.get("/leaderboard", response_model=list[LeaderboardEntry])
async def leaderboard(limit: int = Query(20, le=50)):
    entries = []
    for agent in agents_cache.values():
        completed = agent.get("tasks_completed", 0)
        entries.append(
            {
                "agent_id": agent["agent_id"],
                "name": agent["name"],
                "reputation": agent.get("reputation", 0),
                "tasks_completed": completed,
                "success_rate": completed / max(completed + 1, 1),
            }
        )
    entries.sort(key=lambda x: x["reputation"], reverse=True)
    return entries[:limit]


# --- Health Check (component-level, cacheable) ---

_HEALTH_CACHE_SECONDS = 10


async def _check_db() -> dict:
    """Check database connectivity."""
    t0 = time.perf_counter()
    try:
        db = SessionLocal()
        db.execute(db.bind.dialect.do_ping(db.bind))
        db.close()
        latency = round((time.perf_counter() - t0) * 1000, 2)
        return {"status": "healthy", "latency_ms": latency}
    except Exception as exc:
        latency = round((time.perf_counter() - t0) * 1000, 2)
        return {"status": "unhealthy", "latency_ms": latency, "error": str(exc)}


async def _check_rpc() -> dict:
    """Check RPC endpoint if configured."""
    rpc_url = os.getenv("RPC_URL", "").strip()
    if not rpc_url:
        return {"status": "not_configured", "latency_ms": 0}
    t0 = time.perf_counter()
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.post(rpc_url, json={"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1})
            resp.raise_for_status()
            latency = round((time.perf_counter() - t0) * 1000, 2)
            return {"status": "healthy", "latency_ms": latency, "block": resp.json().get("result")}
    except Exception as exc:
        latency = round((time.perf_counter() - t0) * 1000, 2)
        return {"status": "unhealthy", "latency_ms": latency, "error": str(exc)}


async def _check_disk() -> dict:
    """Check available disk space."""
    t0 = time.perf_counter()
    try:
        usage = shutil.disk_usage(os.getcwd())
        free_gb = round(usage.free / (1024 ** 3), 2)
        total_gb = round(usage.total / (1024 ** 3), 2)
        pct_free = round(usage.free / usage.total * 100, 1)
        latency = round((time.perf_counter() - t0) * 1000, 2)
        healthy = free_gb > 0.5  # < 500 MB free → unhealthy
        return {
            "status": "healthy" if healthy else "unhealthy",
            "latency_ms": latency,
            "free_gb": free_gb,
            "total_gb": total_gb,
            "pct_free": pct_free,
        }
    except Exception as exc:
        latency = round((time.perf_counter() - t0) * 1000, 2)
        return {"status": "unhealthy", "latency_ms": latency, "error": str(exc)}


async def _check_memory() -> dict:
    """Check available system memory."""
    t0 = time.perf_counter()
    try:
        mem = psutil.virtual_memory()
        free_gb = round(mem.available / (1024 ** 3), 2)
        total_gb = round(mem.total / (1024 ** 3), 2)
        pct_used = mem.percent
        latency = round((time.perf_counter() - t0) * 1000, 2)
        healthy = pct_used < 95  # > 95% used → unhealthy
        return {
            "status": "healthy" if healthy else "unhealthy",
            "latency_ms": latency,
            "free_gb": free_gb,
            "total_gb": total_gb,
            "pct_used": pct_used,
        }
    except Exception as exc:
        latency = round((time.perf_counter() - t0) * 1000, 2)
        return {"status": "unhealthy", "latency_ms": latency, "error": str(exc)}


@app.get("/health")
async def health():
    t0 = time.perf_counter()
    db_status = await _check_db()
    rpc_status = await _check_rpc()
    disk_status = await _check_disk()
    mem_status = await _check_memory()

    components = {
        "database": db_status,
        "rpc": rpc_status,
        "disk": disk_status,
        "memory": mem_status,
    }

    # Overall: 503 if any component is unhealthy, 200 otherwise
    any_unhealthy = any(c.get("status") == "unhealthy" for c in components.values())
    overall_status = "unhealthy" if any_unhealthy else "healthy"
    status_code = 503 if any_unhealthy else 200
    total_latency_ms = round((time.perf_counter() - t0) * 1000, 2)

    return JSONResponse(
        status_code=status_code,
        content={
            "status": overall_status,
            "latency_ms": total_latency_ms,
            "timestamp": datetime.utcnow().isoformat(),
            "agents_indexed": len(agents_cache),
            "tasks_indexed": len(tasks_cache),
            "components": components,
        },
        headers={"Cache-Control": f"public, max-age={_HEALTH_CACHE_SECONDS}"},
    )
