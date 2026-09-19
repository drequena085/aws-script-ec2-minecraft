import os
import base64
import boto3
import json

ec2 = boto3.client('ec2')

# Configuración parametrizada
AMI_ID = "ami-xxxxxxxxxxxxxxxxx"        # ID de Amazon Linux 2023 en us-east-1
INSTANCE_TYPE = "t2.large"
SECURITY_GROUP_ID = "sg-xxxxxxxxxxxx"    # Tu Security Group de Minecraft
IAM_ROLE_ARN = "arn:aws:iam::123456789012:instance-profile/TuRolMinecraft"
KEY_NAME = "tu-keypair"                  # Opcional (deja vacío si no usas SSH)
SECRET_TOKEN = "secret_token"

# Definición de la etiqueta requerida
SERVER_TAG_KEY = 'key'
SERVER_TAG_VALUE = 'value'

# Cargar tu script UserData completo
USER_DATA_SCRIPT = """#!/bin/bash
# ... Tu script UserData completo parametrizado ...
"""

def lambda_handler(event, context):

    # Verificar token en los parámetros de la URL
    query_params = event.get('queryStringParameters') or {}
    token = query_params.get('token')
    
    if token != SECRET_TOKEN:
        return {
            'statusCode': 403,
            'body': json.dumps('Acceso denegado: Token inválido')
        }

    # 2. Verificar si ya existe una instancia activa con la etiqueta exacta
    existing_instances = ec2.describe_instances(
        Filters=[
            {'Name': f'tag:{SERVER_TAG_KEY}', 'Values': [SERVER_TAG_VALUE]},
            {'Name': 'instance-state-name', 'Values': ['pending', 'running']}
        ]
    )
        
    # Extraer IDs de instancias encontradas
    active_ids = [
        i['InstanceId'] 
        for r in existing_instances['Reservations'] 
        for i in r['Instances']
    ]

    # Si ya existe al menos una máquina encendida o iniciando, abortar la creación
    if active_ids:
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'message': f'El servidor ya se encuentra en ejecucion.',
                'instance_id': active_ids[0],
                'action': 'none'
            })
        }    

    encoded_user_data = base64.b64encode(USER_DATA_SCRIPT.encode('utf-8')).decode('utf-8')
    
    response = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType=INSTANCE_TYPE,
        MinCount=1,
        MaxCount=1,
        SecurityGroupIds=[SECURITY_GROUP_ID],
        IamInstanceProfile={'Arn': IAM_ROLE_ARN},
        UserData=encoded_user_data,
        # Configurar para que el disco EBS se elimine al destruir la instancia
        BlockDeviceMappings=[
            {
                'DeviceName': '/dev/xvda',
                'Ebs': {
                    'VolumeSize': 8,
                    'VolumeType': 'gp3',
                    'DeleteOnTermination': True
                }
            }
        ],
        TagSpecifications=[
            {
                'ResourceType': 'instance',
                'Tags': [{'Key': SERVER_TAG_KEY, 'Value': SERVER_TAG_VALUE}]
            }
        ]
    )
    
    instance_id = response['Instances'][0]['InstanceId']
    return {
        'statusCode': 200,
        'body': f'Instancia {instance_id} desplegada exitosamente.'
    }
