#pragma once
extern int h_errno;
struct hostent { char *h_name; char **h_aliases; int h_addrtype, h_length; char **h_addr_list; };
struct hostent *gethostbyname(const char *);
struct hostent *gethostbyaddr(const void *, unsigned, int);
