import os
import psycopg2

def get_connection():
    """
    Devuelve una nueva conexión psycopg2.
    Usa variables de entorno: PGHOST, PGPORT, PGUSER, PGPASSWORD, DATABASE.
    Valores por defecto pensados para tu entorno local.
    """
    return psycopg2.connect(
        host=os.getenv('PGHOST', 'localhost'),
        port=os.getenv('PGPORT', '5432'),
        database=os.getenv('DATABASE', 'bdpep'),
        user=os.getenv('PGUSER', 'postgres'),
        password=os.getenv('PGPASSWORD', '123456')
    )
