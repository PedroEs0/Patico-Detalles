# Servidor mínimo Flask -> npm/pip: pip install flask flask-cors psycopg2-binary python-dotenv
from flask import Flask, request, jsonify
from flask_cors import CORS
import os
import base64
import datetime
import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..', 'Base de datos'))
import bd

app = Flask(__name__)
CORS(app)

def foto_bytea_to_dataurl(bytea):
	"""Convierte bytea (bytes) a data URL base64 para uso en img src."""
	if not bytea:
		return None
	try:
		b64 = base64.b64encode(bytea).decode('utf-8')
		# Asumir png si no hay info; clientes pueden renderizar igualmente
		return f"data:image/png;base64,{b64}"
	except Exception:
		return None

def dataurl_to_bytea(dataurl):
	"""Convierte data URL (data:image/xxx;base64,...) a bytes para insertar en bytea."""
	if not dataurl:
		return None
	if ',' in dataurl:
		_, b64 = dataurl.split(',', 1)
	else:
		b64 = dataurl
	try:
		return base64.b64decode(b64)
	except Exception:
		return None

@app.route('/api/ping', methods=['GET'])
def ping():
	try:
		now = bd.fetchall('SELECT NOW() as now')
		return jsonify({'ok': True, 'serverTime': now[0]['now']})
	except Exception as e:
		return jsonify({'ok': False, 'error': str(e)}), 500

@app.route('/api/login', methods=['POST'])
def login():
	data = request.get_json() or {}
	username = data.get('usuario')
	password = data.get('password')
	if not username or not password:
		return jsonify({'success': False, 'message': 'Usuario y contraseña requeridos'}), 400
	try:
		# Tabla real: tmusuarios(pkusuario, contra)
		q = 'SELECT pkusuario, contra FROM tmusuarios WHERE pkusuario = %s LIMIT 1'
		rows = bd.fetchall(q, (username,))
		if not rows:
			return jsonify({'success': False, 'message': 'Usuario no encontrado'}), 401
		user = rows[0]
		# Comparación en texto plano (según tu script). En producción usar hashing.
		if user['contra'] == password:
			return jsonify({'success': True, 'username': user['pkusuario']})
		else:
			return jsonify({'success': False, 'message': 'Contraseña incorrecta'}), 401
	except Exception as e:
		return jsonify({'success': False, 'message': 'Error del servidor', 'error': str(e)}), 500

@app.route('/api/inventory', methods=['GET'])
def get_inventory():
	try:
		# Unir reabastecer con inventario para obtener cantidad actual (restantes).
		q = """
		SELECT 
			r.pkcodigo::text as id,
			r.pkcodigo::text as codigo,
			r.nombre,
			r.precio_unitario::numeric as precio_unitario,
			r.foto as foto_bytea,
			COALESCE(d.restantes, r.cantidad)::integer as cantidad_actual,
			r.fecha_adquisicion as fecha_adq,
			r.fecha_vencimiento as fecha_venc,
			r.proveedor,
			r.precio_unitario::numeric as costo_unit,
			r.costo_total::numeric as costo_total,
			-- usar la fecha actual como ultima_actualizacion si no hay campo propio
			to_char(now()::date, 'DD/MM/YYYY') as ultima_actualizacion,
			r.notas
		FROM tmreabastecer r
		LEFT JOIN tdinventario d ON d.fkcodigo = r.pkcodigo;
		"""
		rows = bd.fetchall(q)
		# Transformar foto bytea a data URL base64 y mapear nombres a los esperados por el frontend
		result = []
		for r in rows:
			img = foto_bytea_to_dataurl(r.get('foto_bytea'))
			result.append({
				'id': r.get('id'),
				'codigo': str(r.get('codigo')),
				'nombre': r.get('nombre'),
				'precio_venta': float(r.get('precio_unitario')) if r.get('precio_unitario') is not None else 0,
				'imagen': img or 'https://via.placeholder.com/60',
				'cantidad_actual': int(r.get('cantidad_actual') or 0),
				'fecha_adq': r.get('fecha_adq') or 'N/A',
				'fecha_venc': r.get('fecha_venc') or 'N/A',
				'proveedor': r.get('proveedor') or '',
				'costo_unit': float(r.get('costo_unit') or 0),
				'costo_total': float(r.get('costo_total') or 0),
				'ultima_actualizacion': r.get('ultima_actualizacion') or '',
				'notas': r.get('notas') or ''
			})
		return jsonify(result)
	except Exception as e:
		return jsonify({'error': str(e)}), 500

@app.route('/api/product', methods=['POST'])
def save_product():
    data = request.get_json() or {}
    # Campos esperados desde el formulario
    codigo = data.get('codigo')
    nombre = data.get('nombre')
    categoria = data.get('categoria') or 'otros'
    precio_unit = data.get('precioUnitario') or data.get('precio_unitario') or 0
    cantidad = data.get('cantidad') or 0
    proveedor = data.get('proveedor') or ''
    fecha_adq = data.get('fechaAdquisicion') or data.get('fecha_adquisicion') or None
    fecha_venc = data.get('fechaVencimiento') or data.get('fecha_vencimiento') or 'No aplica'
    foto_b64 = data.get('foto')  # data URL base64 o null
    notas = data.get('notas') or ''

    if not codigo or not nombre:
        return jsonify({'success': False, 'message': 'Faltan campos obligatorios'}), 400

    try:
        pk = None
        try:
            pk = int(str(codigo))
        except Exception:
            pk = int(datetime.datetime.now().timestamp() % 1000000000)

        # Convertir valores numéricos
        costo_unit = float(precio_unit or 0)
        cantidad_num = int(cantidad or 0)
        costo_total = float(data.get('costoTotal') or (costo_unit * cantidad_num))

        # Aquí está el cambio principal: mantener foto existente si no se provee una nueva
        foto_bytes = None
        if foto_b64:
            foto_bytes = dataurl_to_bytea(foto_b64)
        else:
            # Verificar si ya existe una foto para este código
            check_query = "SELECT foto FROM tmreabastecer WHERE pkcodigo = %s"
            existing = bd.fetchall(check_query, (pk,))
            if existing:
                # Si existe un registro, usar None para mantener la foto existente en UPDATE
                foto_bytes = None

        # Insertar en tmreabastecer con ON CONFLICT
        q1 = """
        INSERT INTO tmreabastecer(pkcodigo, categoria, nombre, foto, fecha_adquisicion, fecha_vencimiento, notas, comprobado_por, proveedor, precio_unitario, cantidad, costo_total, fkid)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,1)
        ON CONFLICT (pkcodigo) DO UPDATE SET
            categoria = EXCLUDED.categoria,
            nombre = EXCLUDED.nombre,
            foto = COALESCE(EXCLUDED.foto, tmreabastecer.foto),
            fecha_adquisicion = EXCLUDED.fecha_adquisicion,
            fecha_vencimiento = EXCLUDED.fecha_vencimiento,
            notas = EXCLUDED.notas,
            comprobado_por = EXCLUDED.comprobado_por,
            proveedor = EXCLUDED.proveedor,
            precio_unitario = EXCLUDED.precio_unitario,
            cantidad = EXCLUDED.cantidad,
            costo_total = EXCLUDED.costo_total;
        """

        params1 = (pk, categoria, nombre, foto_bytes, fecha_adq, fecha_venc, notas, data.get('comprobadoPor') or '', 
                  proveedor, costo_unit, cantidad_num, costo_total)
        
        affected1 = bd.execute(q1, params1)

        # Actualizar inventario
        q2 = """
        INSERT INTO tdinventario(fkcodigo, restantes, fkid)
        VALUES (%s, %s, 1)
        ON CONFLICT (fkcodigo) DO UPDATE SET restantes = EXCLUDED.restantes;
        """
        params2 = (pk, cantidad_num)
        affected2 = bd.execute(q2, params2)

        return jsonify({'success': True, 'affected_reabastecer': affected1, 'affected_inventario': affected2})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/venta', methods=['POST'])
def save_venta():
    data = request.get_json() or {}
    nombre = data.get('nombre')
    archivo = data.get('archivo')
    total_venta = data.get('total_venta')
    productos = data.get('productos', [])

    if not all([nombre, archivo, total_venta]):
        return jsonify({'success': False, 'message': 'Faltan campos requeridos'}), 400

    try:
        archivo_bytes = base64.b64decode(archivo)

        with bd.get_connection() as conn:
            with conn.cursor() as cur:
                # 1. Insertar venta principal
                cur.execute("""
                    INSERT INTO tmventas(nombre, fecha_venta, archivo, total_venta)
                    VALUES (%s, CURRENT_DATE, %s, %s)
                    RETURNING pknum_factura
                """, (nombre, archivo_bytes, total_venta))
                pknum_factura = cur.fetchone()[0]

                # 2. Insertar detalles de la venta y actualizar inventario
                for p in productos:
                    codigo = str(p.get('codigo'))
                    cantidad = int(p.get('cantidad') or 0)
                    if cantidad <= 0:
                        continue

                    # Insertar detalle de venta vinculado a la factura.
                    # La actualización del inventario y las notificaciones la maneja
                    # ahora la base de datos mediante el trigger `tr_actualizar_inventario`.
                    cur.execute("""
                        INSERT INTO tdventas(fknum_factura, fkcodigo, cantidad)
                        VALUES (%s, %s, %s)
                    """, (pknum_factura, codigo, cantidad))

                # 3. Commit de la transacción
                conn.commit()

        return jsonify({
            'success': True,
            'pknum_factura': pknum_factura,
            'message': 'Venta registrada correctamente'
        })

    except Exception as e:
        print(f"Error al procesar la venta: {str(e)}")
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/notificaciones', methods=['GET'])
def get_notificaciones():
    try:
             # Devolver todas las notificaciones (las no leídas se usan para el badge)
             q = """
             SELECT n.id_notificacion, n.mensaje, n.fecha_creacion, n.leida,
                 r.nombre as producto_nombre, r.pkcodigo as producto_codigo, i.restantes
             FROM tmnotificaciones n
             LEFT JOIN tmreabastecer r ON r.pkcodigo = n.fkcodigo
             LEFT JOIN tdinventario i ON i.fkcodigo = r.pkcodigo
             ORDER BY n.fecha_creacion DESC
             LIMIT 200;
             """
             rows = bd.fetchall(q)
             # Asegurar que los tipos sean serializables por JSON (psycopg2 RealDictCursor ya los da bien)
             return jsonify(rows)
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/notificaciones/<int:id>/marcar-leida', methods=['POST'])
def marcar_notificacion_leida(id):
    try:
        q = "UPDATE tmnotificaciones SET leida = true WHERE id_notificacion = %s"
        affected = bd.execute(q, (id,))
        return jsonify({'success': True, 'affected': affected})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
	port = int(os.getenv('PORT', 3000))
	# Ejecutar con: python server.py
	app.run(host='0.0.0.0', port=port, debug=True)
