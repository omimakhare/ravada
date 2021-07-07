use warnings;
use strict;

use Carp qw(confess);
use Data::Dumper;
use Mojo::JSON qw(decode_json);
use Ravada::Request;
use Ravada::WebSocket;
use Test::More;

use lib 't/lib';
use Test::Ravada;

no warnings "experimental::signatures";
use feature qw(signatures);

use_ok('Ravada::HostDevice::Templates');

####################################################################

sub _set_hd_nvidia($hd) {
    $hd->_data( list_command => ['lspci','-Dnn']);
    $hd->_data( list_filter => 'VGA.*NVIDIA');
}

sub test_hd_in_domain($vm , $hd) {

    if ($vm->type eq 'KVM' && $hd->{name} =~ /USB/) {
        diag("TODO test ".$vm->type." $hd->{name} ");
        return;
    }
    my $domain = create_domain($vm);
    if ($vm->type eq 'KVM' && $hd->{name} =~ /PCI/) {
        _set_hd_nvidia($hd);
        if (!$hd->list_devices) {
            diag("SKIPPED: No devices found ".join(" ",$hd->list_command)." | ".$hd->list_filter);
            remove_domain($domain);
            return;
        }
    }
    diag("Testing HD ".$hd->{name}." ".$hd->list_filter." in ".$vm->type);
    $domain->add_host_device($hd);
    $domain->start(user_admin);

    $domain->shutdown_now(user_admin);
    $domain->prepare_base(user_admin);
    my $n_locked = _count_locked();
    for my $count (reverse 0 .. $hd->list_devices ) {
        my $clone = $domain->clone(name => new_domain_name() ,user => user_admin);
        _compare_hds($domain, $clone);
        diag($clone->name);
        eval { $clone->start(user_admin) };
        if (!$count) {
            like($@,qr/No available devices/);
            last;
        }
        is(_count_locked(),++$n_locked) or exit;
        test_device_locked($clone);
    }
    remove_domain($domain);

}

sub test_device_locked($clone) {
    my $sth = connector->dbh->prepare("SELECT id_host_device,name,is_locked FROM host_devices_domain WHERE id_domain=?");
    $sth->execute($clone->id);
    while ( my ($id_hd, $name, $is_locked) = $sth->fetchrow ) {
        is($is_locked,1,"Expecting locked=1 $name") or exit;
        my $hd = Ravada::HostDevice->search_by_id($id_hd);
        my @available= $hd->list_available_devices();
        ok(!grep /^$name$/, @available) or die Dumper($name,\@available);
    }
}

sub _compare_hds($base, $clone) {
    my @hds_base;
    my $sth = connector->dbh->prepare("SELECT id_host_device FROM host_devices_domain WHERE id_domain=?");
    $sth->execute($base->id);
    while ( my ($name) = $sth->fetchrow ) {
        push @hds_base,($name);
    }
    is(scalar(@hds_base),1);
    my @hds_clone;
    $sth = connector->dbh->prepare("SELECT id_host_device FROM host_devices_domain WHERE id_domain=?");
    $sth->execute($clone->id);
    while ( my ($name) = $sth->fetchrow ) {
        push @hds_clone,($name);
    }
    is_deeply(\@hds_clone,\@hds_base) or exit;

}

sub _count_locked() {
    my $sth = connector->dbh->prepare("SELECT count(*) FROM host_devices_domain "
        ." WHERE is_locked=1 ");
    $sth->execute();
    my ($n) = $sth->fetchrow;
    return $n;
}

sub test_templates($vm) {
    my $templates = Ravada::HostDevice::Templates::list_templates($vm->type);
    ok(@$templates);

    my $templates2 = Ravada::HostDevice::Templates::list_templates($vm->id);
    is_deeply($templates2,$templates);

    my $n=scalar($vm->list_host_devices);

    for my $first  (@$templates) {

        diag("Tsting $first->{name} Hostdev on ".$vm->type);
        $vm->add_host_device(template => $first->{name});

        my @list_hostdev = $vm->list_host_devices();
        is(scalar @list_hostdev, $n+1, Dumper(\@list_hostdev)) or exit;

        $vm->add_host_device(template => $first->{name});
        @list_hostdev = $vm->list_host_devices();
        is(scalar @list_hostdev, $n+2);
        like ($list_hostdev[-1]->{name} , qr/[a-zA-Z] \d+$/) or exit;

        test_hd_in_domain($vm, $list_hostdev[-1]);

        my $req = Ravada::Request->list_host_devices(
            uid => user_admin->id
            ,id_host_device => $list_hostdev[-1]->id
            ,_force => 1
        );
        wait_request( debug => 0);
        is($req->status, 'done');
        my $ws_args = {
            channel => '/'.$vm->id
            ,login => user_admin->name
        };
        my $devices = Ravada::WebSocket::_list_host_devices(rvd_front(), $ws_args);
        is(scalar(@$devices), 2+$n) or die Dumper($devices, $list_hostdev[-1]);
        ok(scalar(@{$devices->[-1]->{devices}})>1);
        $n++;

        $list_hostdev[-1]->_data('list_filter' => '002');
        my $req2 = Ravada::Request->list_host_devices(
            uid => user_admin->id
            ,id_host_device => $list_hostdev[-1]->id
            ,_force => 1
        );
        wait_request();
        is($req2->status, 'done');
        is($req2->error, '');
        my $devices2 = Ravada::WebSocket::_list_host_devices(rvd_front(), $ws_args);
        isnt(scalar(@{$devices2->[-1]->{devices}}) , scalar(@{$devices->[-1]->{devices}}));
        $n++;
    }

}

####################################################################

clean();

for my $vm_name ( reverse vm_names()) {
    my $vm;
    eval { $vm = rvd_back->search_vm($vm_name) };

    SKIP: {

        my $msg = "SKIPPED: $vm_name virtual manager not found ".($@ or '');

        diag($msg)      if !$vm;
        skip($msg,10)   if !$vm;

        diag("Testing host devices in $vm_name");

        test_templates($vm);

    }
}

end();
done_testing();
