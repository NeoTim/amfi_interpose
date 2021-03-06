
#include <CoreFoundation/CoreFoundation.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <glob.h>
#include <vproc.h>

#include <sys/sysctl.h>
#include <syslog.h>

#include "tar.h"

#define _log
#define _assert(x) x
#define _assert_zero(x) x

static int run(char **argv, char **envp) {
    if(envp == NULL) envp = *((char ***)_NSGetEnviron());
    fprintf(stderr, "run:");
    for(char **p = argv; *p; p++) {
        fprintf(stderr, " %s", *p);
    }
    fprintf(stderr, "\n");

    pid_t pid;
    int stat;
    if(posix_spawn(&pid, argv[0], NULL, NULL, argv, envp)) return 255;
    if(pid != waitpid(pid, &stat, 0)) return 254;
    if(!WIFEXITED(stat)) return 253;
    return WEXITSTATUS(stat);
}


// returns whether the plist existed
static bool modify_plist(NSString *filename, void (^func)(id)) {
    NSData *data = [NSData dataWithContentsOfFile:filename];
    if(!data) {
        _log("did not modify %@", filename);
        return false;
    }
    NSPropertyListFormat format;
    NSError *error;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:&format error:&error];
    _assert(plist);

    func(plist);

    NSData *new_data = [NSPropertyListSerialization dataWithPropertyList:plist format:format options:0 error:&error];
    _assert(new_data);

    _assert([new_data writeToFile:filename atomically:YES]);

    _log("modified %@", filename);
    return true;
}

static void dok48() {
    char model[32];
    size_t model_size = sizeof(model);
    _assert_zero(sysctlbyname("hw.model", model, &model_size, NULL, 0));

    NSString *filename = [NSString stringWithFormat:@"/System/Library/CoreServices/SpringBoard.app/%s.plist", model];
    modify_plist(filename, ^(id plist) {
        [[plist objectForKey:@"capabilities"] setObject:[NSNumber numberWithBool:false] forKey:@"hide-non-default-apps"];
    });
}

static void add_afc2() {
    _assert(modify_plist(@"/System/Library/Lockdown/Services.plist", ^(id services) {
        NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSArray arrayWithObjects:@"/usr/libexec/afcd",
                                                          @"--lockdown",
                                                          @"-d",
                                                          @"/",
                                                          nil], @"ProgramArguments",
                                [NSNumber numberWithBool:true], @"AllowUnauthenticatedServices",
                                @"com.apple.afc2",              @"Label",
                                                                nil];
        [services setValue:args forKey:@"com.apple.afc2"];
    }));
}

@interface LSApplicationWorkspace { }
+(LSApplicationWorkspace *)defaultWorkspace;
-(BOOL)registerApplication:(id)application;
-(BOOL)unregisterApplication:(id)application;
@end

static void uicache() {
    // I am not using uicache because I want loc_s to do the reloading

    // probably not safe:
    NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Caches/com.apple.mobile.installation.plist"];
    if(cache) {
        NSMutableDictionary *cydia = _assert([NSMutableDictionary dictionaryWithContentsOfFile:@"/Applications/Cydia.app/Info.plist"]);
        [cydia setObject:@"/Applications/Cydia.app" forKey:@"Path"];
        [cydia setObject:@"System" forKey:@"ApplicationType"];
        id system = [cache objectForKey:@"System"];
        if([system respondsToSelector:@selector(addObject:)])
            [system addObject:cydia];
        else
            [system setObject:cydia forKey:@"com.saurik.Cydia"];
        [cache writeToFile:@"/var/mobile/Library/Caches/com.apple.mobile.installation.plist" atomically:YES];
    }

    NSURL *url = [NSURL fileURLWithPath:@"/Applications/Cydia.app"];
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    [workspace unregisterApplication:url];
    [workspace registerApplication:url];

    system("killall installd");
    system("launchctl unload /Library/LaunchDaemons/*");
    system("launchctl load /Library/LaunchDaemons/*");
}


int main(int argc, char **argv) {
    syslog(LOG_EMERG, "hi there from jailbreak");

    syslog(LOG_EMERG, "first, remounting fs");
    run((char *[]) {"/sbin/mount", "-u", "-o", "rw,suid,dev", "/", NULL}, NULL);
    NSString *string = [NSString stringWithContentsOfFile:@"/etc/fstab" encoding:NSUTF8StringEncoding error:NULL];
    string = [string stringByReplacingOccurrencesOfString:@",nosuid,nodev" withString:@""];
    string = [string stringByReplacingOccurrencesOfString:@" ro " withString:@" rw "];
    [string writeToFile:@"/etc/fstab" atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    syslog(LOG_EMERG, "patching");
    dok48();
    add_afc2();

    syslog(LOG_EMERG, "bootstrap!");
    if (access("/var/mobile/Media/bootstrap.tar", F_OK) != -1) {
        syslog(LOG_EMERG, "using custom");
        untar("/var/mobile/Media/bootstrap.tar", "/");
    } else {
        untar("/Developer/bootstrap.tar", "/");
    }

    chown("/Applications/Cydia.app/MobileCydia", 0, 0);
    chmod("/Applications/Cydia.app/MobileCydia", 06755);

    syslog(LOG_EMERG, "uicache time...");
    uicache();
    syslog(LOG_EMERG, "done");

    // install deb
    if (access("/private/var/mobile/Media/auto.deb", F_OK) != -1) {
        syslog(LOG_EMERG, "DEB EXISTS, INSTALLING");
        run((char *[]) {"/usr/bin/dpkg", "-i", "/private/var/mobile/Media/auto.deb", NULL}, NULL);
        syslog(LOG_EMERG, "DONE");
    }

    syslog(LOG_EMERG, "killing sb");
    system("killall SpringBoard");
    syslog(LOG_EMERG, "killed sb.");

    return 0;
}


