clear all;
xx=0:200;
fi=tekal('open','depth.tek');
xd=tekal('read',fi,1)
dd=interp1(xd(:,1),xd(:,2),xx);
fi=tekal('open','eta.tek');
xe=tekal('read',fi,1)
eta=interp1(xe(:,1),xe(:,2),xx);
eta(isnan(eta))=4.6;
hh=eta-dd;
a=dir ('rtf*')
for i=1:length(a);
    fi=tekal('open',a(i).name);
    x(i)=str2num(a(i).name(5:7))
    zu=tekal('read',fi,1);
    z=zu(:,1);
    u=zu(:,2);
    h=interp1(xx,hh,x(i));
    umean(i)=.5*(sum((z(2:end)-z(1:end-1)).*(u(1:end-1)+u(2:end)))+(h-z(end))*u(end))/h;
end
data(:,1)=x;data(:,2)=umean;
fi=tekal('write','umean.tek',data);