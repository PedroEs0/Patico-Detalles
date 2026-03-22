import os
from psycopg2.extras import RealDictCursor
from db_conn import get_connection

# Helper para consultas que devuelven filas como dicts
def fetchall(query, params=()):
	conn = get_connection()
	try:
		with conn.cursor(cursor_factory=RealDictCursor) as cur:
			cur.execute(query, params)
			return cur.fetchall()
	finally:
		conn.close()

# Helper para ejecutar inserts/updates/deletes
def execute(query, params=()):
	conn = get_connection()
	try:
		with conn.cursor() as cur:
			cur.execute(query, params)
			conn.commit()
			# devolver número de filas afectadas
			return cur.rowcount
	finally:
		conn.close()

