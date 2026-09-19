import json
import boto3

ec2 = boto3.client('ec2')

SECRET_TOKEN = "secret_token"      # Tu token de seguridad

# Definición de la etiqueta requerida
SERVER_TAG_KEY = 'key'
SERVER_TAG_VALUE = 'value'

def lambda_handler(event, context):
    # Validar el token enviado en la URL (?token=...)
    query_params = event.get('queryStringParameters') or {}
    token = query_params.get('token') or event.get('token')
        
    if token != SECRET_TOKEN:
        return {
            'statusCode': 403,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'error': 'Acceso denegado: Token invalido'})
        }
    # Obtener el ID de la instancia enviado por el evento o buscar por Tag
    instance_id = event.get('instance_id')
    
    if not instance_id:
        # Buscar por Tag si no se especificó un ID
        response = ec2.describe_instances(
            Filters=[
                {'Name': f'tag:{SERVER_TAG_KEY}', 'Values': [SERVER_TAG_VALUE]},
                {'Name': 'instance-state-name', 'Values': ['running', 'stopping']}
            ]
        )
        instances = [i['InstanceId'] for r in response['Reservations'] for i in r['Instances']]
        if instances:
            instance_id = instances[0]

    if instance_id:
        ec2.terminate_instances(InstanceIds=[instance_id])
        return {
            'statusCode': 200,
            'body': f'Instancia {instance_id} enviada a destrucción.'
        }
    
    return {
        'statusCode': 404,
        'body': 'No se encontraron instancias activas para destruir.'
    }
