-- =====================================================
-- SEED PARA AMBIENTE DE DESENVOLVIMENTO APENAS
-- =====================================================
-- ATENCAO: Nao utilizar em producao!
-- Gere credenciais unicas e fortes para cada ambiente.
--
-- Idempotente: pode ser aplicado sobre um banco ja inicializado
-- pelo config/DB/cftv_gml.sql (que cria apenas o admin).
-- A conta de dev fica sem troca obrigatoria de senha (senha_temporaria = 0).
--
-- Senha padrao (DEV apenas):
--   admin -> admin@123
-- =====================================================

-- Substitua pela sua senha de banco local
-- DROP USER IF EXISTS 'gmluser'@'localhost';
-- CREATE USER 'gmluser'@'localhost' IDENTIFIED BY 'ykB]Af4|2kHPU#;1g+?J3z)P]=p|AX=R'; senha temporaria para desenvolvimento, altere para uma senha forte e unica em producao
-- GRANT ALL PRIVILEGES ON cftv_gml.* TO 'gmluser'@'localhost';
-- FLUSH PRIVILEGES;

-- Substitua pela sua senha de banco local : admin@123

INSERT INTO usuarios (nome, usuario, senha, nivel_acesso_id, secretaria_id, senha_temporaria, ativo) VALUES
('Administrador Sistema','admin','$2y$12$3.lPsNIBYzzIJ3ZqVIOtAOZ47d/qo4qf2CtBnrb9bVAIj8axwUBlK',1,NULL,0,1)
ON DUPLICATE KEY UPDATE
    nome = VALUES(nome),
    senha = VALUES(senha),
    nivel_acesso_id = VALUES(nivel_acesso_id),
    senha_temporaria = VALUES(senha_temporaria),
    ativo = VALUES(ativo);
