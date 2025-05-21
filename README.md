# matrix-server
搭建matrix聊天服务器，并且支持federation通信，数据库替换为PostgreSQL.                                                                             
一.需要准备的东西：                                                                                                                             
1.两个域名：分别用于matrix服务器和element前端.                                                                                                   
2.由于注册时启用邮箱验证，故需准备smtp邮箱和专用密码.                                                                                             
3.启用第三方账号登陆（可选），脚本里用的是谷歌账号和github账号，故需准备相关api密钥  .                                                               
二.注意事项：                                                                                                                                  
1.nginx反代上传文件最大限制为:50M，这个可以修改.                                                                                             
2.VPS机器内存最好为2G及以上.


